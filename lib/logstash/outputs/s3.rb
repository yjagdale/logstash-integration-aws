# encoding: utf-8
require "logstash/outputs/base"
require "logstash/namespace"
require "logstash/plugin_mixins/aws_config"
require "stud/temporary"
require "stud/task"
require "concurrent"
require "socket"
require "thread"
require "tmpdir"
require "fileutils"
require "set"
require "pathname"
require "aws-sdk-s3"

# INFORMATION:
#
# This plugin batches and uploads logstash events into Amazon Simple Storage Service (Amazon S3).
#
# Requirements:
# * Amazon S3 Bucket and S3 Access Permissions (Typically access_key_id and secret_access_key)
# * S3 PutObject permission
#
# S3 outputs create temporary files into the OS' temporary directory, you can specify where to save them using the `temporary_directory` option.
#
# S3 output files have the following format
#
# ls.s3.312bc026-2f5d-49bc-ae9f-5940cf4ad9a6.2013-04-18T10.00.tag_hello.part0.txt
#
#
# |=======
# | ls.s3 | indicate logstash plugin s3 |
# | 312bc026-2f5d-49bc-ae9f-5940cf4ad9a6 | a new, random uuid per file. |
# | 2013-04-18T10.00 | represents the time whenever you specify time_file. |
# | tag_hello | this indicates the event's tag. |
# | part0 | this means if you indicate size_file then it will generate more parts if you file.size > size_file. When a file is full it will be pushed to the bucket and then deleted from the temporary directory. If a file is empty, it is simply deleted.  Empty files will not be pushed |
# |=======
#
# Crash Recovery:
# * This plugin will recover and upload temporary log files after crash/abnormal termination when using `restore` set to true
#
##[Note regarding time_file and size_file] :
#
## Both time_file and size_file settings can trigger a log "file rotation"
## A log rotation pushes the current log "part" to s3 and deleted from local temporary storage.
#
## If you specify BOTH size_file and time_file then it will create file for each tag (if specified).
## When EITHER time_file minutes have elapsed OR log file size > size_file, a log rotation is triggered.
##
## If you ONLY specify time_file but NOT file_size, one file for each tag (if specified) will be created.
## When time_file minutes elapses, a log rotation will be triggered.
#
## If you ONLY specify size_file, but NOT time_file, one files for each tag (if specified) will be created.
## When size of log file part > size_file, a log rotation will be triggered.
#
## If NEITHER size_file nor time_file is specified, ONLY one file for each tag (if specified) will be created.
## WARNING: Since no log rotation is triggered, S3 Upload will only occur when logstash restarts.
#
#
# #### Usage:
# This is an example of logstash config:
# [source,ruby]
# output {
#    s3{
#      access_key_id => "crazy_key"             (required)
#      secret_access_key => "monkey_access_key" (required)
#      region => "eu-west-1"                    (optional, default = "us-east-1")
#      bucket => "your_bucket"                  (required)
#      size_file => 2048                        (optional) - Bytes
#      time_file => 5                           (optional) - Minutes
#      codec => "plain"                         (optional)
#      canned_acl => "private"                  (optional. Options are "private", "public-read", "public-read-write", "authenticated-read", "aws-exec-read", "bucket-owner-read", "bucket-owner-full-control", "log-delivery-write". Defaults to "private" )
#    }
#
class LogStash::Outputs::S3 < LogStash::Outputs::Base
  require "logstash/outputs/s3/writable_directory_validator"
  require "logstash/outputs/s3/path_validator"
  require "logstash/outputs/s3/write_bucket_permission_validator"
  require "logstash/outputs/s3/size_rotation_policy"
  require "logstash/outputs/s3/time_rotation_policy"
  require "logstash/outputs/s3/size_and_time_rotation_policy"
  require "logstash/outputs/s3/temporary_file"
  require "logstash/outputs/s3/temporary_file_factory"
  require "logstash/outputs/s3/uploader"
  require "logstash/outputs/s3/file_repository"

  include LogStash::PluginMixins::AwsConfig::V2

  PREFIX_KEY_NORMALIZE_CHARACTER = "_"
  PERIODIC_CHECK_INTERVAL_IN_SECONDS = 15
  CRASH_RECOVERY_THREADPOOL = Concurrent::ThreadPoolExecutor.new({
                                                                   :min_threads => 1,
                                                                   :max_threads => 2,
                                                                   :fallback_policy => :caller_runs
                                                                 })

  GZIP_ENCODING = "gzip"

  config_name "s3"
  default :codec, "line"

  concurrency :shared

  # S3 bucket
  config :bucket, :validate => :string, :required => true

  config :additional_settings, :validate => :hash, :default => {}

  # Set the size of file in bytes, this means that files on bucket when have dimension > file_size, they are stored in two or more file.
  # If you have tags then it will generate a specific size file for every tags
  #
  # NOTE: define size of file is the better thing, because generate a local temporary file on disk and then put it in bucket.
  config :size_file, :validate => :number, :default => 1024 * 1024 * 5

  # Set the time, in MINUTES, to close the current sub_time_section of bucket.
  # If you also define file_size you have a number of files related to the section and the current tag.
  # If it's valued 0 and rotation_strategy is 'time' or 'size_and_time' then the plugin reaise a configuration error.
  config :time_file, :validate => :number, :default => 15

  # If `restore => false` is specified and Logstash crashes, the unprocessed files are not sent into the bucket.
  #
  # NOTE: that the `recovery => true` default assumes multiple S3 outputs would set a unique `temporary_directory => ...`
  # if they do not than only a single S3 output is safe to recover (since let-over files are processed and deleted).
  config :restore, :validate => :boolean, :default => true

  # The S3 canned ACL to use when putting the file. Defaults to "private".
  config :canned_acl, :validate => ["private", "public-read", "public-read-write", "authenticated-read", "aws-exec-read", "bucket-owner-read", "bucket-owner-full-control", "log-delivery-write"],
         :default => "private"

  # Specifies whether or not to use S3's server side encryption. Defaults to no encryption.
  config :server_side_encryption, :validate => :boolean, :default => false

  # Specifies what type of encryption to use when SSE is enabled.
  config :server_side_encryption_algorithm, :validate => ["AES256", "aws:kms"], :default => "AES256"

  # The key to use when specified along with server_side_encryption => aws:kms.
  # If server_side_encryption => aws:kms is set but this is not default KMS key is used.
  # http://docs.aws.amazon.com/AmazonS3/latest/dev/UsingKMSEncryption.html
  config :ssekms_key_id, :validate => :string

  # Specifies what S3 storage class to use when uploading the file.
  # More information about the different storage classes can be found:
  # http://docs.aws.amazon.com/AmazonS3/latest/dev/storage-class-intro.html
  # Defaults to STANDARD.
  config :storage_class, :validate => ["STANDARD", "REDUCED_REDUNDANCY", "STANDARD_IA", "ONEZONE_IA"], :default => "STANDARD"

  # Set the directory where logstash will store the tmp files before sending it to S3
  # default to the current OS temporary directory in linux /tmp/logstash
  #
  # NOTE: the reason we do not have a unique (isolated) temporary directory as a default, to support multiple plugin instances,
  # is that we would have to rely on something static that does not change between restarts (e.g. a user set id => ...).
  config :temporary_directory, :validate => :string, :default => File.join(Dir.tmpdir, "logstash")

  # Specify a prefix to the uploaded filename, this can simulate directories on S3.  Prefix does not require leading slash.
  # This option support string interpolation, be warned this can created a lot of temporary local files.
  config :prefix, :validate => :string, :default => ''

  # Specify how many workers to use to upload the files to S3
  config :upload_workers_count, :validate => :number, :default => (Concurrent.processor_count * 0.5).ceil

  # Number of items we can keep in the local queue before uploading them
  config :upload_queue_size, :validate => :number, :default => 2 * (Concurrent.processor_count * 0.25).ceil

  # Files larger than this number are uploaded using the S3 multipart APIs. Default threshold is 15MB.
  config :upload_multipart_threshold, :validate => :number, :default => 15 * 1024 * 1024

  # The version of the S3 signature hash to use. Normally uses the internal client default, can be explicitly
  # specified here
  config :signature_version, :validate => ['v2', 'v4']

  # Define tags to be appended to the file on the S3 bucket.
  #
  # Example:
  # tags => ["elasticsearch", "logstash", "kibana"]
  #
  # Will generate this file:
  # "ls.s3.logstash.local.2015-01-01T00.00.tag_elasticsearch.logstash.kibana.part0.txt"
  #
  config :tags, :validate => :array, :default => []

  # Specify the content encoding. Supports ("gzip"). Defaults to "none"
  config :encoding, :validate => ["none", GZIP_ENCODING], :default => "none"

  # Define the strategy to use to decide when we need to rotate the file and push it to S3,
  # The default strategy is to check for both size and time, the first one to match will rotate the file.
  config :rotation_strategy, :validate => ["size_and_time", "size", "time"], :default => "size_and_time"

  # The common use case is to define permission on the root bucket and give Logstash full access to write its logs.
  # In some circonstances you need finer grained permission on subfolder, this allow you to disable the check at startup.
  config :validate_credentials_on_root_bucket, :validate => :boolean, :default => true

  # The number of times to retry a failed S3 upload.
  config :retry_count, :validate => :number, :default => Float::INFINITY

  # The amount of time to wait in seconds before attempting to retry a failed upload.
  config :retry_delay, :validate => :number, :default => 1

  def register
    # I've move the validation of the items into custom classes
    # to prepare for the new config validation that will be part of the core so the core can
    # be moved easily.
    unless @prefix.empty?
      if !PathValidator.valid?(prefix)
        raise LogStash::ConfigurationError, "Prefix must not contains: #{PathValidator::INVALID_CHARACTERS}"
      end
    end

    if !WritableDirectoryValidator.valid?(@temporary_directory)
      raise LogStash::ConfigurationError, "Logstash must have the permissions to write to the temporary directory: #{@temporary_directory}"
    end

    if @validate_credentials_on_root_bucket && !WriteBucketPermissionValidator.new(@logger).valid?(bucket_resource, upload_options)
      raise LogStash::ConfigurationError, "Logstash must have the privileges to write to root bucket `#{@bucket}`, check your credentials or your permissions."
    end

    if @time_file.nil? && @size_file.nil? || @size_file == 0 && @time_file == 0
      raise LogStash::ConfigurationError, "The S3 plugin must have at least one of time_file or size_file set to a value greater than 0"
    end

    @file_repository = FileRepository.new(@tags, @encoding, @temporary_directory)

    @rotation = rotation_strategy

    executor = Concurrent::ThreadPoolExecutor.new({ :min_threads => 1,
                                                    :max_threads => @upload_workers_count,
                                                    :max_queue => @upload_queue_size,
                                                    :fallback_policy => :caller_runs })

    @uploader = Uploader.new(bucket_resource, @logger, executor, retry_count: @retry_count, retry_delay: @retry_delay)

    # Restoring from crash will use a new threadpool to slowly recover
    # New events should have more priority.
    restore_from_crash if @restore

    # If we need time based rotation we need to do periodic check on the file
    # to take care of file that were not updated recently
    start_periodic_check if @rotation.needs_periodic?
  end

  def multi_receive_encoded(events_and_encoded)
    prefix_written_to = Set.new

    events_and_encoded.each do |event, encoded|
      prefix_key = normalize_key(event.sprintf(@prefix))
      prefix_written_to << prefix_key

      begin
        @file_repository.get_file(prefix_key) { |file| file.write(encoded) }
        # The output should stop accepting new events coming in, since it cannot do anything with them anymore.
        # Log the error and rethrow it.
      rescue Errno::ENOSPC => e
        @logger.error("S3: No space left in temporary directory", :temporary_directory => @temporary_directory)
        raise e
      end
    end

    # Groups IO calls to optimize fstat checks
    rotate_if_needed(prefix_written_to)
  end

  def close
    stop_periodic_check if @rotation.needs_periodic?

    @logger.debug("Uploading current workspace")

    @file_repository.shutdown # stop stale sweeps

    # The plugin has stopped receiving new events, but we still have
    # data on disk, lets make sure it get to S3.
    # If Logstash get interrupted, the `restore_from_crash` (when set to true) method will pickup
    # the content in the temporary directly and upload it.
    # This will block the shutdown until all upload are done or the use force quit.
    @file_repository.each_files do |file|
      upload_file(file)
    end

    @uploader.stop # wait until all the current upload are complete
    @crash_uploader.stop if @restore # we might have still work to do for recovery so wait until we are done
  end

  def full_options
    options = aws_options_hash || {}
    options[:signature_version] = @signature_version if @signature_version
    symbolized_settings.merge(options)
  end

  def symbolized_settings
    @symbolized_settings ||= symbolize_keys_and_cast_true_false(@additional_settings)
  end

  def symbolize_keys_and_cast_true_false(hash)
    case hash
    when Hash
      symbolized = {}
      hash.each { |key, value| symbolized[key.to_sym] = symbolize_keys_and_cast_true_false(value) }
      symbolized
    when 'true'
      true
    when 'false'
      false
    else
      hash
    end
  end

  def normalize_key(prefix_key)
    prefix_key.gsub(PathValidator.matches_re, PREFIX_KEY_NORMALIZE_CHARACTER)
  end

  def upload_options
    {
      :acl => @canned_acl,
      :server_side_encryption => @server_side_encryption ? @server_side_encryption_algorithm : nil,
      :ssekms_key_id => @server_side_encryption_algorithm == "aws:kms" ? @ssekms_key_id : nil,
      :storage_class => @storage_class,
      :content_encoding => @encoding == GZIP_ENCODING ? GZIP_ENCODING : nil,
      :multipart_threshold => @upload_multipart_threshold
    }
  end

  private
  # We start a task in the background for check for stale files and make sure we rotate them to S3 if needed.
  def start_periodic_check
    @logger.debug("Start periodic rotation check")

    @periodic_check = Concurrent::TimerTask.new(:execution_interval => PERIODIC_CHECK_INTERVAL_IN_SECONDS) do
      @logger.debug("Periodic check for stale files")

      rotate_if_needed(@file_repository.keys)
    end

    @periodic_check.execute
  end

  def stop_periodic_check
    @periodic_check.shutdown
  end

  def bucket_resource
    Aws::S3::Bucket.new(@bucket, full_options)
  end

  def rotate_if_needed(prefixes)
    # Each file access is thread safe,
    # until the rotation is done then only
    # one thread has access to the resource.
    @file_repository.each_factory(prefixes) do |factory|
      # we have exclusive access to the one-and-only
      # prefix WRAPPER for this factory.
      temp_file = factory.current

      if @rotation.rotate?(temp_file)
        @logger.debug? && @logger.debug("Rotate file",
                                        :key => temp_file.key,
                                        :path => temp_file.path,
                                        :strategy => @rotation.class.name)

        upload_file(temp_file) # may be async or blocking
        factory.rotate!
      end
    end
  end

  def upload_file(temp_file)
    @logger.debug? && @logger.debug("Queue for upload", :path => temp_file.path)

    # if the queue is full the calling thread will be used to upload
    temp_file.close # make sure the content is on disk
    if temp_file.size > 0
      @uploader.upload_async(temp_file,
                             :on_complete => method(:clean_temporary_file),
                             :upload_options => upload_options )
    end
  end

  def rotation_strategy
    case @rotation_strategy
    when "size"
      SizeRotationPolicy.new(size_file)
    when "time"
      TimeRotationPolicy.new(time_file)
    when "size_and_time"
      SizeAndTimeRotationPolicy.new(size_file, time_file)
    end
  end

  def clean_temporary_file(file)
    @logger.debug? && @logger.debug("Removing temporary file", :path => file.path)
    file.delete!
  end

  # The upload process will use a separate uploader/threadpool with less resource allocated to it.
  # but it will use an unbounded queue for the work, it may take some time before all the older files get processed.
  def restore_from_crash
    @crash_uploader = Uploader.new(bucket_resource, @logger, CRASH_RECOVERY_THREADPOOL)

    temp_folder_path = Pathname.new(@temporary_directory)
    files = Dir.glob(::File.join(@temporary_directory, "**/*"))
               .select { |file_path| ::File.file?(file_path) }
    under_recovery_files = get_under_recovery_files(files)

    files.each do |file_path|
      # when encoding is GZIP, if file is already recovering or recovered and uploading to S3, log and skip
      if under_recovery_files.include?(file_path)
        unless file_path.include?(TemporaryFile.gzip_extension)
          @logger.warn("The #{file_path} file either under recover process or failed to recover before.")
        end
      else
        temp_file = TemporaryFile.create_from_existing_file(file_path, temp_folder_path)
        # do not remove or upload if Logstash tries to recover file but fails
        if temp_file.recoverable?
          if temp_file.size > 0
            @logger.debug? && @logger.debug("Recovering from crash and uploading", :path => temp_file.path)
            @crash_uploader.upload_async(temp_file,
                                         :on_complete => method(:clean_temporary_file),
                                         :upload_options => upload_options)
          else
            clean_temporary_file(temp_file)
          end
        end
      end
    end
  end

  # figures out the recovering files and
  # creates a skip list to ignore for the rest of processes
  def get_under_recovery_files(files)
    skip_files = Set.new
    return skip_files unless @encoding == GZIP_ENCODING

    files.each do |file_path|
      if file_path.include?(TemporaryFile.recovery_file_name_tag)
        skip_files << file_path
        if file_path.include?(TemporaryFile.gzip_extension)
          # also include the original corrupted gzip file
          skip_files << file_path.gsub(TemporaryFile.recovery_file_name_tag, "")
        end
      end
    end
    skip_files
  end
end

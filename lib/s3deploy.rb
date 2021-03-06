require "s3deploy/version"
require "aws/s3"
require "digest/md5"
require "yaml"

class S3deploy

  AWS_REGIONS = %W(us-west-2 us-west-1 eu-west-1 ap-southeast-1 ap-northeast-1 sa-east-1)

  def self.config_files?
    File.exists?( File.expand_path "~/.s3deploy/.s3deploy.yml" ) || File.exists?( File.expand_path "./.s3deploy.yml" )
  end

  def initialize(options = {})
    defaults = { "path" => ".", "remote_path" => "" }
    @options = defaults.merge(options)
    @options.merge! import_settings(File.expand_path("~/.s3deploy/.s3deploy.yml"))
    @options.merge! import_settings(File.expand_path("./.s3deploy.yml"))

    @options["extras"] ||= []

    raise "No AWS credentials given." unless @options["aws_key"] && @options["aws_secret"]

    set_aws_region(@options["aws_region"]) if @options["aws_region"]

    AWS::S3::Base.establish_connection!(
      :access_key_id     => @options["aws_key"],
      :secret_access_key => @options["aws_secret"]
    )

    raise "No bucket selected." unless @options["aws_bucket"]
    @bucket = AWS::S3::Bucket.find @options["aws_bucket"]
  end

  def deploy(simulate = false)

    path = File.expand_path(@options["path"])
    raise "#{@options["path"]} is not a path." unless File.directory? path

    puts simulate ? "Simulating deployment to #{@options["aws_bucket"]}" : "Deploying to #{@options["aws_bucket"]}"

    files = all_files(path).map { |f| f.gsub(/^#{path}\//, "")}

    if @options["skip_regex"]
      files.delete_if { |f| f =~ Regexp.new(@options["skip_regex"]) }
    end

    skip_files = []
    active_files = []
    files.each do |file|
      next if skip_files.include? file

      full_path = (path + "/" + file).gsub( /\/\//, "/")
      full_remote_path = (@options["remote_path"] + "/" + file).gsub( /\/\//, "/").gsub( /(^\/)|(\/$)/, "")

      if @options["extras"].include?("replace_with_gzip") && has_gzip_version?(file, files)
        full_path.gsub!(/.gz$/i, "")
        file.gsub!(/.gz$/i, "")
        full_remote_path.gsub!(/.gz$/i, "")
        skip_files << file << file + ".gz"
        if is_gzip_smaller?(full_path)
          file = file + ".gz"
          full_path = full_path + ".gz"
        end
      end

      active_files << full_remote_path

      if s3_file_exists?(full_path, full_remote_path)
        puts "Skipped\t\t#{full_remote_path}"
        next
      end

      upload_file(full_path, full_remote_path, simulate)
    end

    only_keep(active_files, simulate) if @options["extras"].include?("delete_old_files")

  end

  def has_gzip_version?(file, files)
    (file !~ /.+.gz$/i && files.include?("#{file}.gz")) || ( file =~ /.+.gz$/i && files.include?( file.gsub(/.gz$/i, "") ) )
  end

  def is_gzip_smaller?(full_path)
    open("#{full_path}.gz").size < open("#{full_path}").size
  end

  def only_keep(active_files, simulate)
    @bucket.each do |o|
      unless active_files.include?( o.key )
        AWS::S3::S3Object.delete(o.key, @options["aws_bucket"]) unless simulate
        puts "Deleted\t\t#{o.key}"
      end
    end
  end

  def empty(simulate)
    puts "Emptying #{@options["aws_bucket"]} #{"(Simulating)" if simulate}"
    @bucket.each do |o|
      AWS::S3::S3Object.delete(o.key, @options["aws_bucket"]) unless simulate
      puts "Deleted\t\t#{o.key}"
    end
  end

  def s3_file_exists?(local, remote)
    md5 = Digest::MD5.hexdigest(open(local).read)
    !@bucket.objects.select{|o| o.key == remote && o.etag == md5 }.empty?
  end

  def upload_file(local, remote, simulate, options = {})
    options[:access] = :public_read

    if @options["cache_regex"] && remote =~ Regexp.new(@options["cache_regex"])
      options[:"Cache-Control"] = "public, max-age=31557600"
    end

    options[:content_type] = "text/html; charset=#{@options["html_charset"]}" if @options["html_charset"] && remote =~ /.+\.(html|htm)(\.gz)?$/i
    options[:"Content-Encoding"] = "gzip" if local =~ /.+.gz$/i

    extra_info = []
    extra_info << "cache-headers" if options[:"Cache-Control"]
    extra_info << "gzip" if options[:"Content-Encoding"]
    extra_info << "charset=#{@options["html_charset"]}" if options[:content_type]

    AWS::S3::S3Object.store(remote, open(local), @options["aws_bucket"], options) unless simulate

    message = "Uploaded\t#{remote}"
    message += " (#{extra_info.join(", ")})" unless extra_info.empty?
    puts message
  end

  def self.install_config(default = false)
    install_path = default ? File.expand_path("~/.s3deploy/.s3deploy.yml") : File.expand_path("./.s3deploy.yml")

    raise "Configuration file already exist." if File.exist? install_path

    if default
      `mkdir -p #{File.dirname(install_path)}` unless File.directory? File.dirname(install_path)
    end

    puts `cp #{File.dirname(File.expand_path(__FILE__)) + "/.s3deploy.yml"} #{install_path}`

    puts "A configuration file has been created at #{install_path}"
  end

  def all_files(path = ".")
    files = []
    Dir.new(path).each do |row|
      next if %W{. .. .git}.include? row

      full_path = "#{path}/#{row}"

      if File.directory?(full_path)
        files |= all_files(full_path)
      else
        files << full_path
      end
    end
    files
  end

  def import_settings(file)
    settings = YAML::load_file(file) if File.file? file
    if settings && settings.class == Hash
      settings.delete_if { |k,v| k != "aws_region" && v.nil? }
    else
      Hash.new
    end
  end

  def set_aws_region(region)

    unless AWS_REGIONS.include? region.downcase
      raise "#{region} is not a valid region, please select from #{AWS_REGIONS.join(", ")} or leave it blank for US Standard."
    end

    AWS::S3::DEFAULT_HOST.replace "s3-#{region}.amazonaws.com"

  end

end

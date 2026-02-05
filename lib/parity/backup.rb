require "etc"

module Parity
  class Backup
    BLANK_ARGUMENTS = "".freeze
    DATABASE_YML_RELATIVE_PATH = "config/database.yml".freeze
    DEVELOPMENT_ENVIRONMENT_KEY_NAME = "development".freeze
    DATABASE_KEY_NAME = "database".freeze

    def initialize(args)
      @from, @to = args.values_at(:from, :to)
      @additional_args = args[:additional_args] || BLANK_ARGUMENTS
      @parallelize = args[:parallelize] || false
      @backup_id = args[:backup_id]
    end

    def restore
      if to == DEVELOPMENT_ENVIRONMENT_KEY_NAME
        restore_to_development
      elsif from == DEVELOPMENT_ENVIRONMENT_KEY_NAME
        restore_from_development
      else
        restore_to_remote_environment
      end
    end

    private

    attr_reader :additional_args, :from, :to, :parallelize, :backup_id

    alias_method :parallelize?, :parallelize

    def log_restore_info
      if backup_id
        puts "Restoring from #{from} backup ID: #{backup_id} to #{to}"
      else
        puts "Restoring from #{from} (latest backup) to #{to}"
      end
      puts "Starting backup restoration process..."
    end

    def restore_from_development
      log_restore_info
      reset_remote_database
      Kernel.system(
        "heroku pg:push #{development_db} DATABASE_URL --remote #{to} " \
          "#{additional_args}"
      )
      puts "Backup restoration to #{to} completed successfully!"
    end

    def restore_to_development
      log_restore_info
      ensure_temp_directory_exists
      download_remote_backup
      wipe_development_database
      create_heroku_ext_schema
      restore_from_local_temp_backup
      delete_local_temp_backup
      delete_rails_production_environment_settings
      puts "Backup restoration to #{to} completed successfully!"
    end

    def wipe_development_database
      Kernel.system(
        "dropdb --if-exists #{development_db} --force && createdb #{development_db}"
      )
    end

    def create_heroku_ext_schema
      Kernel.system(<<~SHELL)
        psql #{development_db} -c "
          CREATE SCHEMA IF NOT EXISTS heroku_ext;
        "
      SHELL
    end

    def reset_remote_database
      Kernel.system(
        "heroku pg:reset --remote #{to} #{additional_args} " \
          "--confirm #{heroku_app_name}"
      )
    end

    def heroku_app_name
      HerokuAppName.new(to).to_s
    end

    def ensure_temp_directory_exists
      Kernel.system("mkdir -p tmp")
    end

    def download_remote_backup
      if backup_id
        puts "Downloading backup #{backup_id} from #{from}..."
        Kernel.system(
          "curl -o tmp/#{backup_id}.backup \"$(heroku pg:backups:url #{backup_id} --remote #{from})\""
        )
      else
        puts "Downloading latest backup from #{from}..."
        Kernel.system(
          "curl -o tmp/latest.backup \"$(heroku pg:backups:url --remote #{from})\""
        )
      end
    end

    def restore_from_local_temp_backup
      puts "Restoring backup to #{development_db}..."
      # Filter out --backup-id from additional_args as it's not needed for pg_restore
      filtered_args = additional_args.gsub(/--backup-id\s+\S+/, "").strip
      backup_filename = backup_id ? "#{backup_id}.backup" : "latest.backup"
      Kernel.system(
        "pg_restore tmp/#{backup_filename} --verbose --no-acl --no-owner " \
          "--dbname #{development_db} --jobs=#{processor_cores} " \
          "#{filtered_args}"
      )
    end

    def delete_local_temp_backup
      backup_filename = backup_id ? "#{backup_id}.backup" : "latest.backup"
      Kernel.system("rm tmp/#{backup_filename}")
    end

    def delete_rails_production_environment_settings
      Kernel.system(<<-SHELL)
        psql #{development_db} -c "CREATE TABLE IF NOT EXISTS public.ar_internal_metadata (key character varying NOT NULL, value character varying, created_at timestamp without time zone NOT NULL, updated_at timestamp without time zone NOT NULL, CONSTRAINT ar_internal_metadata_pkey PRIMARY KEY (key)); UPDATE ar_internal_metadata SET value = 'development' WHERE key = 'environment'"
      SHELL
    end

    def restore_to_remote_environment
      log_restore_info
      reset_remote_database
      # Filter out --backup-id from additional_args as it's handled separately
      filtered_args = additional_args.gsub(/--backup-id\s+\S+/, "").strip
      Kernel.system(
        "heroku pg:backups:restore #{backup_from} --remote #{to} " \
          "#{filtered_args}"
      )
      puts "Backup restoration to #{to} completed successfully!"
    end

    def backup_from
      "`#{remote_db_backup_url}` DATABASE"
    end

    def remote_db_backup_url
      if backup_id
        "heroku pg:backups:url #{backup_id} --remote #{from}"
      else
        "heroku pg:backups:url --remote #{from}"
      end
    end

    def development_db
      YAML.safe_load(database_yaml_file, aliases: true)
        .fetch(DEVELOPMENT_ENVIRONMENT_KEY_NAME)
        .fetch(DATABASE_KEY_NAME)
    end

    def database_yaml_file
      # Load Rails environment if Rails is not already loaded
      # This is needed when database.yml uses Rails.application.credentials
      unless defined?(Rails)
        require File.expand_path("config/environment", Dir.pwd)
      end
      ERB.new(IO.read(DATABASE_YML_RELATIVE_PATH)).result
    end

    def processor_cores
      if parallelize? && ruby_version_over_2_2?
        Etc.nprocessors
      else
        1
      end
    end

    def ruby_version_over_2_2?
      Etc.respond_to?(:nprocessors)
    end
  end
end

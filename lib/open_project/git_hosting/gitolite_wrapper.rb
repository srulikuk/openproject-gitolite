require 'gitolite'

module OpenProject::GitHosting
  module GitoliteWrapper

    # Used to register errors when pulling and pushing the conf file
    class GitHostingException < StandardError
      attr_reader :command
      attr_reader :output

      def initialize(command, output)
        @command = command
        @output  = output
      end
    end

    def self.logger
      Rails.logger
    end

    def logger
      self.class.logger
    end

    def self.gitolite_user
      Setting.plugin_openproject_git_hosting[:gitolite_user]
    end

    def self.gitolite_url
      [gitolite_user, '@localhost'].join
    end

    def self.gitolite_command
      if gitolite_version == 2
        'gl-setup'
      else
        'gitolite setup'
      end
    end

    def self.gitolite_version
      Rails.cache.fetch(GitHosting.cache_key('gitolite_version')) do
        logger.debug("Gitolite updating version")
        out, err, code = ssh_shell('info')
        return 3 if out.include?('running gitolite3')
        return 2 if out =~ /gitolite[ -]v?2./
        logger.error("Couldn't retrieve gitolite version through SSH.")
        logger.debug("Gitolite version error output: #{err}") unless err.nil?
      end
    end

    @@openproject_user = nil
    def self.openproject_user
      @@openproject_user = (%x[whoami]).chomp.strip if @@openproject_user.nil?
      @@openproject_user
    end

    def self.http_server_domain
      Setting.plugin_openproject_git_hosting[:http_server_domain]
    end


    def self.https_server_domain
      Setting.plugin_openproject_git_hosting[:https_server_domain]
    end


    def self.gitolite_server_port
      Setting.plugin_openproject_git_hosting[:gitolite_server_port]
    end

    def self.ssh_server_domain
      Setting.plugin_openproject_git_hosting[:ssh_server_domain]
    end


    def self.gitolite_ssh_private_key
      Setting.plugin_openproject_git_hosting[:gitolite_ssh_private_key]
    end


    def self.gitolite_ssh_public_key
      Setting.plugin_openproject_git_hosting[:gitolite_ssh_public_key]
    end


    def self.git_config_username
      Setting.plugin_openproject_git_hosting[:git_config_username]
    end


    def self.git_config_email
      Setting.plugin_openproject_git_hosting[:git_config_email]
    end

    def self.true?(setting)
      ['true', '1'].include?(Setting.plugin_openproject_git_hosting[setting])
    end

    def self.gitolite_commit_author
      "#{git_config_username} <#{git_config_email}>"
    end

    def self.gitolite_hooks_url
      [Setting.protocol, '://', Setting.host_name, '/githooks/post-receive/redmine'].join
    end

    def self.gitolite_admin_settings
      {
          git_user: gitolite_user,
          host: ssh_server_domain,

          author_name: git_config_username,
          author_email: git_config_email,

          public_key: gitolite_ssh_public_key,
          private_key: gitolite_ssh_private_key,

          key_subdir: 'openproject',
          config_file: 'openproject.conf'
      }
    end



    ##########################
    #                        #
    #   SUDO Shell Wrapper   #
    #                        #
    ##########################


    #
    # Execute a command as the gitolite user defined in +GitoliteWrapper.gitolite_user+.
    #
    # Will shell out to +sudo -n -u <gitolite_user> params+
    #
    def self.sudo_shell(*params)
      GitHosting.shell('sudo', *sudo_shell_params.concat(params))
    end

    #
    # Execute a command as the gitolite user defined in +GitoliteWrapper.gitolite_user+.
    #
    # Instead of capturing the command, it calls the block with the stdout pipe.
    # Raises an exception if the command does not exit with 0.
    #
    def self.sudo_pipe(*params, &block)
      Open3.popen3("sudo", *sudo_shell_params.concat(params))  do |stdin, stdout, stderr, thr|
        begin
          exitcode = thr.value.exitstatus
          if exitcode != 0
            logger.error("sudo call with '#{params.join(" ")}' returned exit #{exitcode}. Error was: #{stderr.read}")
          else
            block.call(stdout)
          end
        ensure
          stdout.close
          stdin.close
        end
      end
    end


    # Return only the output of the shell command
    # Throws an exception if the shell command does not exit with code 0.
    def self.sudo_capture(*params)
      GitHosting.capture('sudo', *sudo_shell_params.concat(params))
    end

    # Returns the sudo prefix to all sudo_* commands
    #
    # These are as follows:
    # * (-i) login as `gitolite_user` (setting ENV['HOME')
    # * (-n) non-interactive
    # * (-u `gitolite_user`) target user
    def self.sudo_shell_params
      ['-i', '-n', '-u', gitolite_user]
    end

    # Calls mkdir with the given arguments on the git user's side.
    #
    # e.g., sudo_mkdir('-p', '/some/path)
    #
    def self.sudo_mkdir(*args)
      sudo_capture('mkdir', *args)
    rescue => e
      logger.error("Couldn't move '#{old_path}' => '#{new_path}'. Reason: #{e.message}")
    end

    # Moves a file/directory to a new target.
    # Creates the parent of the target path using mkdir -p.
    #
    def self.sudo_move(old_path, new_path)
      sudo_mkdir('-p', File.dirname(new_path))
      sudo_capture('mv', old_path, new_path)
    rescue => e
      logger.error("Couldn't move '#{old_path}' => '#{new_path}'. Reason: #{e.message}")
    end

    # Removes a directory and all subdirectories below gitolite_user's $HOME.
    #
    # Assumes a relative path.
    #
    # If force=true, it will delete using 'rm -rf <path>', otherwise
    # it uses rmdir
    def self.sudo_rmdir(relative_path, force=false)
      repo_path = File.join('$HOME', relative_path)
      logger.debug("Deleting '#{repo_path}' [forced=#{force ? 'no' : 'yes'}] with git user")

      if force
        sudo_capture('rm','-rf', repo_path)
      else
        sudo_capture('rmdir', repo_path)
      end
    rescue => e
      logger.error("Could not delete repository '#{relative_path}' from disk: #{e.message}")
    end

    # Test if a file or directory exists and is readable to the gitolite user
    # Prepends '$HOME/' to the given path.
    def self.file_exists?(filename)
      sudo_test(filename, '-r')
    end

    # Test if a given path is an empty directory using the git user.
    #
    # Prepends '$HOME/' to the given path.
    def self.sudo_directory_empty?(path)
      home_path = File.join('$HOME', path)
      out, _ , code = GitoliteWrapper.sudo_shell('find', home_path, '-prune', '-empty', '-type', 'd')
      return code == 0 && out.include?(path)
    end

    ##########################
    #                        #
    #       SSH Wrapper      #
    #                        #
    ##########################

    # Execute a command in the gitolite forced environment through this user
    # i.e., executes 'ssh git@localhost <command>'
    #
    # Returns stdout, stderr and the exit code
    def self.ssh_shell(*params)
      GitHosting.shell('ssh', *ssh_shell_params.concat(params))
    end

    # Return only the output from the ssh command and checks
    def self.ssh_capture(*params)
      GitHosting.capture('ssh', *ssh_shell_params.concat(params))
    end

    # Returns the ssh prefix arguments for all ssh_* commands
    #
    # These are as follows:
    # * (-T) Never request tty
    # * (-i <gitolite_ssh_private_key>) Use the SSH keys given in Settings
    # * (-p <gitolite_server_port>) Use port from settings
    # * (-o BatchMode=yes) Never ask for a password
    # * <gitolite_user>@localhost (see +gitolite_url+)
    def self.ssh_shell_params
      ['-T', '-o', 'BatchMode=yes', gitolite_url, '-p',
        gitolite_server_port, '-i', gitolite_ssh_private_key]
    end

    ##########################
    #                        #
    #   Gitolite Accessor    #
    #                        #
    ##########################

    def self.admin
      admin_dir = Setting.plugin_openproject_git_hosting[:gitolite_admin_dir]
      logger.info { "Acessing gitolite-admin.git at '#{admin_dir}'" }
      Gitolite::GitoliteAdmin.new(admin_dir, gitolite_admin_settings)
    end

    WRAPPERS = [GitoliteWrapper::Admin, GitoliteWrapper::Repositories,
      GitoliteWrapper::Users, GitoliteWrapper::Projects]

    # Update the Gitolite Repository
    #
    # action: An API action defined in one of the gitolite/* classes.
    def self.update(action, object, options={})
      WRAPPERS.each do |wrappermod|
        if wrappermod.method_defined?(action)
          return wrappermod.new(action,object,options).run
        end
      end

      raise GitHostingException.new(action, "No available Wrapper for action '#{action}' found.")
    end


    ##########################
    #                        #
    #  Config Tests / Setup  #
    #                        #
    ##########################


    # Returns the gitolite welcome/info banner, containing its version.
    #
    # Upon error, returns the shell error code instead.
    def self.gitolite_banner
      Rails.cache.fetch(GitHosting.cache_key('gitolite_banner')) {
        logger.debug("Retrieving gitolite banner")
        begin
          GitoliteWrapper.ssh_capture('info')
        rescue => e
          errstr = "Error while getting Gitolite banner: #{e.message}"
          logger.error(errstr)
          errstr
        end
      }
    end

    # Test if the current user can sudo to the gitolite user
    def self.can_sudo_to_gitolite_user?
      Rails.cache.fetch(GitHosting.cache_key('test_gitolite_sudo')) {
        begin
          test = GitoliteWrapper.sudo_capture('whoami')
          test =~ /#{GitoliteWrapper.gitolite_user}/i
        rescue => e
          logger.error("Exception during sudo config test: #{e.message}")
          false
        end
      }
    end


    # Test properties of a path from the git user.
    # Prepends '$HOME/' to the given path
    #
    # e.g., Test if a directory exists: sudo_test('$HOME/somedir', '-d')
    def self.sudo_test(path, *testarg)
      path = File.join('$HOME', path)
      out, _ , code = GitoliteWrapper.sudo_shell('test', *testarg, path)
      return code == 0
    rescue => e
      logger.debug("File check for #{path} failed: #{e.message}")
      false
    end


    ###############################
    ##                           ##
    ##      MIRRORING KEYS       ##
    ##                           ##
    ###############################

    GITOLITE_DEFAULT_CONFIG_FILE       = 'gitolite.conf'
    GITOLITE_IDENTIFIER_DEFAULT_PREFIX = 'redmine_'

    GITOLITE_MIRRORING_KEYS_NAME   = "redmine_gitolite_admin_id_rsa_mirroring"
    GITOLITE_SSH_PRIVATE_KEY_PATH  = "~/.ssh/#{GITOLITE_MIRRORING_KEYS_NAME}"
    GITOLITE_SSH_PUBLIC_KEY_PATH   = "~/.ssh/#{GITOLITE_MIRRORING_KEYS_NAME}.pub"
    GITOLITE_MIRRORING_SCRIPT_PATH = '~/.ssh/run_gitolite_admin_ssh'

    @@mirroring_public_key = nil

    def self.mirroring_public_key
      if @@mirroring_public_key.nil?
        public_key = (%x[ cat '#{gitolite_ssh_public_key}' ]).chomp.strip
        @@mirroring_public_key = public_key.split(/[\t ]+/)[0].to_s + " " + public_key.split(/[\t ]+/)[1].to_s
      end

      return @@mirroring_public_key
    end


    @@mirroring_keys_installed = false

    def self.mirroring_keys_installed?(opts = {})
      @@mirroring_keys_installed = false if opts.has_key?(:reset) && opts[:reset] == true

      if !@@mirroring_keys_installed
        logger.info { "Installing Redmine Gitolite mirroring SSH keys ..." }

        begin
          # GitHosting.execute_command(:shell_cmd, "'cat > #{GITOLITE_SSH_PRIVATE_KEY_PATH}'", :pipe_data => "'#{gitolite_ssh_private_key}'", :pipe_command => 'cat')
          # GitHosting.execute_command(:shell_cmd, "'cat > #{GITOLITE_SSH_PUBLIC_KEY_PATH}'",  :pipe_data => "'#{gitolite_ssh_public_key}'",  :pipe_command => 'cat')

          # GitHosting.execute_command(:shell_cmd, "'chmod 600 #{GITOLITE_SSH_PRIVATE_KEY_PATH}'")
          # GitHosting.execute_command(:shell_cmd, "'chmod 644 #{GITOLITE_SSH_PUBLIC_KEY_PATH}'")

          # git_user_dir = GitHosting.execute_command(:shell_cmd, "'cd ~ && pwd'").chomp.strip

          # command = 'exec ssh -T -o BatchMode=yes -o StrictHostKeyChecking=no -i ' + "#{git_user_dir}/.ssh/#{GITOLITE_MIRRORING_KEYS_NAME}" + ' "$@"'

          # GitHosting.execute_command(:shell_cmd, "'cat > #{GITOLITE_MIRRORING_SCRIPT_PATH}'",  :pipe_data => "#!/bin/sh", :pipe_command => 'echo')
          # GitHosting.execute_command(:shell_cmd, "'cat >> #{GITOLITE_MIRRORING_SCRIPT_PATH}'", :pipe_data => command, :pipe_command => 'echo')

          # GitHosting.execute_command(:shell_cmd, "'chmod 700 #{GITOLITE_MIRRORING_SCRIPT_PATH}'")

          logger.info { "Done !" }

          @@mirroring_keys_installed = true
        rescue GitHosting::GitHostingException => e
          logger.error { "Failed installing Redmine Gitolite mirroring SSH keys !" }
          logger.error { e.output }
          @@mirroring_keys_installed = false
        end
      end

      return @@mirroring_keys_installed
    end
  end
end
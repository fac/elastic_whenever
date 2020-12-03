module ElasticWhenever
  class CLI
    SUCCESS_EXIT_CODE = 0
    ERROR_EXIT_CODE = 1

    class << self
      def run(args)
        option = Option.new(args)
        case option.mode
        when Option::DRYRUN_MODE
          option.validate!
          update_tasks(option, dry_run: true)
          Logger.instance.message("Above is your schedule file converted to scheduled tasks; your scheduled tasks was not updated.")
          Logger.instance.message("Run `elastic_whenever --help' for more options.")
        when Option::UPDATE_MODE
          option.validate!
          with_concurrent_modification_handling do
            update_tasks(option, dry_run: false)
          end
          Logger.instance.log("write", "scheduled tasks updated")
        when Option::PATCH_MODE
          option.validate!
          patch_tasks(option, dry_run: false)
        when Option::CLEAR_MODE
          with_concurrent_modification_handling do
            clear_tasks(option)
          end
          Logger.instance.log("write", "scheduled tasks cleared")
        when Option::LIST_MODE
          list_tasks(option)
          Logger.instance.message("Above is your scheduled tasks.")
          Logger.instance.message("Run `elastic_whenever --help` for more options.")
        when Option::PRINT_VERSION_MODE
          print_version
        end

        SUCCESS_EXIT_CODE
      rescue Aws::Errors::MissingRegionError
        Logger.instance.fail("missing region error occurred; please use `--region` option or export `AWS_REGION` environment variable.")
        ERROR_EXIT_CODE
      rescue Aws::Errors::MissingCredentialsError
        Logger.instance.fail("missing credential error occurred; please specify it with arguments, use shared credentials, or export `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` environment variable.")
        ERROR_EXIT_CODE
      rescue OptionParser::MissingArgument,
        Option::InvalidOptionException,
        Task::Target::InvalidContainerException => exn

        Logger.instance.fail(exn.message)
        ERROR_EXIT_CODE
      end

      private

      def patch_tasks(option, dry_run:)
        schedule = Schedule.new(option.schedule_file, option.verbose, option.variables)

        cluster = Task::Cluster.new(option, option.cluster)
        definition = Task::Definition.new(option, option.task_definition)
        role = Task::Role.new(option)
        if !role.exists? && !dry_run
          role.create
        end

        remote_rules = Task::Rule.fetch(option)
        rules = []
        schedule.tasks.each do |task|
          rule = Task::Rule.convert(option, task)
          rule.create

          remote_targets = Task::Target.fetch(option, rule)

          targets = task.commands.map do |command|
            Task::Target.new(
              option,
              cluster: cluster,
              definition: definition,
              container: option.container,
              commands: command,
              rule: rule,
              role: role,
            )
          end

          # Iterate over all targets and create if not already there
          targets.each do |target|
            exists = remote_targets.any? do |remote_target|
              remote_target.commands == target.commands
            end

            unless exists
              puts "Create target: #{target.commands}"
              target.create
            end
          end

          # Destroy all targets that are no longer valid
          remote_targets.each do |remote_target|
            exists = targets.any? do |target|
              remote_target.commands == target.commands
            end

            unless exists
              puts "Delete target: #{remote_target.commands}"
              remote_target.delete
            end
          end

          rules << rule
        end

        remote_rules.each do |remote_rule|
          remote_targets = Task::Target.fetch(option, remote_rule)

          exists = rules.any? do |rule|
            rule.name == remote_rule.name
          end

          if remote_targets.empty? || !exists
            puts "Delete rule: #{remote_rule.name}"
            remote_rule.delete
          end
        end
      end

      def update_tasks(option, dry_run:)
        schedule = Schedule.new(option.schedule_file, option.verbose, option.variables)

        cluster = Task::Cluster.new(option, option.cluster)
        definition = Task::Definition.new(option, option.task_definition)
        role = Task::Role.new(option)
        if !role.exists? && !dry_run
          role.create
        end

        clear_tasks(option) unless dry_run
        schedule.tasks.each do |task|
          rule = Task::Rule.convert(option, task)
          targets = task.commands.map do |command|
            Task::Target.new(
              option,
              cluster: cluster,
              definition: definition,
              container: option.container,
              commands: command,
              rule: rule,
              role: role,
            )
          end

          if dry_run
            print_task(rule, targets)
          else
            begin
              rule.create
            rescue Aws::CloudWatchEvents::Errors::ValidationException => exn
              Logger.instance.warn("#{exn.message} Ignore this task: name=#{rule.name} expression=#{rule.expression}")
              next
            end
            targets.each(&:create)
          end
        end
      end

      def clear_tasks(option)
        Task::Rule.fetch(option).each(&:delete)
      end

      def list_tasks(option)
        Task::Rule.fetch(option).each do |rule|
          targets = Task::Target.fetch(option, rule)
          print_task(rule, targets)
        end
      end

      def print_version
        puts "Elastic Whenever v#{ElasticWhenever::VERSION}"
      end

      def print_task(rule, targets)
        targets.each do |target|
          puts "#{rule.expression} #{target.cluster.name} #{target.definition.name} #{target.container} #{target.commands.join(" ")}"
          puts
        end
      end

      def with_concurrent_modification_handling
        Retryable.retryable(
          tries: 5,
          on: Aws::CloudWatchEvents::Errors::ConcurrentModificationException,
          sleep: lambda { |_n| rand(1..10) },
        ) do |retries, exn|
          if retries > 0
            Logger.instance.warn("concurrent modification detected; Retrying...")
          end
          yield
        end
      end
    end
  end
end

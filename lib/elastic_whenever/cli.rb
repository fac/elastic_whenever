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

      def update_tasks(option, dry_run:)
        schedule = Schedule.new(option.schedule_file, option.verbose, option.variables)

        cluster = Task::Cluster.new(option, option.cluster)
        definition = Task::Definition.new(option, option.task_definition)
        role = Task::Role.new(option)
        if !role.exists? && !dry_run
          role.create
        end

        remote_rules = Task::Rule.fetch(option) unless dry_run
        rules = schedule.tasks.map do |task|
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
            create_missing_rule(rule, remote_rules)

            remote_targets = Task::Target.fetch(option, rule)
            create_missing_targets(targets, remote_targets)
            delete_invalid_targets(targets, remote_targets)
          end

          # return the rule so we can remove any remote rules
          # which shouldn't exist
          rule
        end

        delete_invalid_rules(option, rules, remote_rules) unless dry_run
      end

      # Creates a rule but only persists the rule remotely if it does not exist
      def create_missing_rule(rule, remote_rules)
        exists = remote_rules.any? do |remote_rule|
          rule.name == remote_rule.name &&
          rule.description == remote_rule.description
        end
        rule.create unless exists
      end

      # Creates a target if it doesn't exist already exist
      def create_missing_targets(targets, remote_targets)
        targets.each do |target|
          exists = remote_targets.any? do |remote_target|
            remote_target.commands == target.commands
          end

          target.create unless exists
        end
      end

      # Deletes a target which has been removed
      def delete_invalid_targets(targets, remote_targets)
        remote_targets.each do |remote_target|
          exists = targets.any? do |target|
            remote_target.commands == target.commands
          end

          remote_target.delete unless exists
        end
      end

      # Deletes rules which no longer have targets or
      # have been completely removed from the schedule
      def delete_invalid_rules(option, rules, remote_rules)
        remote_rules.each do |remote_rule|
          remote_targets = Task::Target.fetch(option, remote_rule)
          exists_in_schedule = rules.any? do |rule|
            rule.name == remote_rule.name
          end

          if remote_targets.empty? || !exists_in_schedule
            remote_rule.delete
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

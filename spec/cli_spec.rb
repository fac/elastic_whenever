require "spec_helper"

RSpec.describe ElasticWhenever::CLI do
  describe "run" do
    let(:task) do
      ElasticWhenever::Task.new("production", false, "bundle exec", "cron(0 0 * * ? *)").tap do |task|
        task.runner("Hoge.run")
      end
    end
    let(:schedule) do
      double(
        environment: "production",
        chronic_options: {},
        tasks: [task]
      )
    end
    let(:cluster) { double(arn: "arn:aws:ecs:us-east-1:123456789:cluster/test", name: "test") }
    let(:definition) { double(arn: "arn:aws:ecs:us-east-1:123456789:task-definition/wordpress:2", name: "wordpress:2", containers: ["testContainer"]) }
    let(:role) { double(arn: "arn:aws:ecs:us-east-1:123456789:role/testRole") }
    let(:rule) { double(name: "test_a1195a39879a5cfc2bb1ab2ba406820bec450ab4", description: "test - cron(0 0 * * ? *) - bundle exec bin/rails runner -e production Hoge.run") }
    before do
      allow(ElasticWhenever::Schedule).to receive(:new).with((Pathname(__dir__) + "fixtures/schedule.rb").to_s, boolean, kind_of(Array)).and_return(schedule)
      allow(ElasticWhenever::Task::Cluster).to receive(:new).with(kind_of(ElasticWhenever::Option), "test").and_return(cluster)
      allow(ElasticWhenever::Task::Definition).to receive(:new).with(kind_of(ElasticWhenever::Option), "wordpress:2").and_return(definition)
      allow(ElasticWhenever::Task::Role).to receive(:new).with(kind_of(ElasticWhenever::Option)).and_return(role)
      allow(role).to receive(:exists?).and_return(false)
    end

    context "with dry run mode" do
      let(:args) do
        %W(
          --region us-east-1
          -f #{Pathname(__dir__) + "fixtures/schedule.rb"}
          --cluster test
          --task-definition wordpress:2
          --container testContainer
        )
      end

      it "updates tasks with dry run" do
        expect(role).not_to receive(:create)
        expect(ElasticWhenever::CLI).not_to receive(:clear_tasks)
        expect_any_instance_of(ElasticWhenever::Task::Rule).not_to receive(:create)
        expect_any_instance_of(ElasticWhenever::Task::Target).not_to receive(:create)

        expect {
          ElasticWhenever::CLI.run(args)
        }.to output(<<~OUTPUT).to_stdout
          cron(0 0 * * ? *) test wordpress:2 testContainer bundle exec bin/rails runner -e production Hoge.run

          ## [message] Above is your schedule file converted to scheduled tasks; your scheduled tasks was not updated.
          ## [message] Run `elastic_whenever --help' for more options.
        OUTPUT
      end

      it "returns success status code" do
        expect(ElasticWhenever::CLI.run(args)).to eq ElasticWhenever::CLI::SUCCESS_EXIT_CODE
      end
    end

    context "with update mode" do
      let(:args) do
        %W(
          -i test
          --region us-east-1
          -f #{Pathname(__dir__) + "fixtures/schedule.rb"}
          --cluster test
          --task-definition wordpress:2
          --container testContainer
        )
      end

      before do
        allow(role).to receive(:create)

        allow_any_instance_of(ElasticWhenever::Task::Rule).to receive(:create)
        allow_any_instance_of(ElasticWhenever::Task::Target).to receive(:create)
        allow(ElasticWhenever::Task::Rule).to receive(:fetch).and_return([])
        allow(ElasticWhenever::Task::Target).to receive(:fetch).and_return([])
      end

      it "creates the missing tasks" do
        expect_any_instance_of(ElasticWhenever::Task::Rule).to receive(:create)
        expect_any_instance_of(ElasticWhenever::Task::Target).to receive(:create)

        expect(ElasticWhenever::CLI.run(args)).to eq ElasticWhenever::CLI::SUCCESS_EXIT_CODE
      end

      it "receives schedule file name and variables" do
        expect(ElasticWhenever::Schedule).to receive(:new).with((Pathname(__dir__) + "fixtures/schedule.rb").to_s, boolean, [{ key: "environment", value: "staging" }, { key: "foo", value: "bar" }])

        ElasticWhenever::CLI.run(args.concat(%W(--set environment=staging&foo=bar)))
      end

      context "with existing targets" do
        let(:target) { double(commands: task.commands.first) }

        before do
          expect(ElasticWhenever::Task::Rule).to receive(:fetch).and_return([rule])
          expect(ElasticWhenever::Task::Target).to receive(:fetch).twice.and_return([target])
        end

        it "does not recreate a target that already exists" do
          expect_any_instance_of(ElasticWhenever::Task::Target).to_not receive(:create)
          expect(target).not_to receive(:delete)

          expect(ElasticWhenever::CLI.run(args)).to eq ElasticWhenever::CLI::SUCCESS_EXIT_CODE
        end
      end

      context "when a target doesn't exist" do
        it "creates the target" do
          expect_any_instance_of(ElasticWhenever::Task::Target).to receive(:create)

          expect(ElasticWhenever::CLI.run(args)).to eq ElasticWhenever::CLI::SUCCESS_EXIT_CODE
        end
      end

      context "when a target should be removed" do
        let(:target) { double(commands: ["command", "to", "remove"]) }

        before do
          expect(ElasticWhenever::Task::Rule).to receive(:fetch).and_return([rule])
          expect(ElasticWhenever::Task::Target).to receive(:fetch).twice.and_return([target])
        end

        it "removes targets that don't exist in the new schedule" do
          expect(target).to receive(:delete)

          expect(ElasticWhenever::CLI.run(args)).to eq ElasticWhenever::CLI::SUCCESS_EXIT_CODE
        end
      end

      context "when a rule should be updated" do
        let(:rule) { double(name: "test_a11566") }

        before do
          expect(ElasticWhenever::Task::Rule).to receive(:fetch).and_return([rule])
          expect(ElasticWhenever::Task::Target).to receive(:fetch).twice.and_return([])
        end

        it "removes the remote rule" do
          expect(rule).to receive(:delete)

          expect(ElasticWhenever::CLI.run(args)).to eq ElasticWhenever::CLI::SUCCESS_EXIT_CODE
        end
      end

      context "when a scheudle has been removed" do
        let(:rule) { double(name: "test_a11566") }
        let(:schedule) do
          double(environment: "production", chronic_options: {}, tasks: [])
        end

        before do
          expect(ElasticWhenever::Task::Rule).to receive(:fetch).and_return([rule])
          expect(ElasticWhenever::Task::Target).to receive(:fetch).with(kind_of(ElasticWhenever::Option), rule).and_return([])
        end

        it "removes the remote rule" do
          expect(rule).to receive(:delete)

          expect(ElasticWhenever::CLI.run(args)).to eq ElasticWhenever::CLI::SUCCESS_EXIT_CODE
        end
      end

      context "when a rule has not changed" do
        let(:target) { double(commands: task.commands.first) }

        before do
          expect(ElasticWhenever::Task::Rule).to receive(:fetch).and_return([rule])
          expect(ElasticWhenever::Task::Target).to receive(:fetch).twice.and_return([target])
        end

        it "does not recreate the rule" do
          expect_any_instance_of(ElasticWhenever::Task::Rule).not_to receive(:create)
          expect(rule).not_to receive(:delete)

          expect(ElasticWhenever::CLI.run(args)).to eq ElasticWhenever::CLI::SUCCESS_EXIT_CODE
        end
      end
    end

    context "with clear mode" do
      let(:rule) { double("Rule") }
      let(:args) do
        %W(
          -c test
          --region us-east-1
          -f #{Pathname(__dir__) + "fixtures/schedule.rb"}
        )
      end

      it "clear tasks" do
        expect(ElasticWhenever::Task::Rule).to receive(:fetch).with(kind_of(ElasticWhenever::Option)).and_return([rule])
        expect(rule).to receive(:delete)

        expect(ElasticWhenever::CLI.run(args)).to eq ElasticWhenever::CLI::SUCCESS_EXIT_CODE
      end
    end

    context "with list mode" do
      let(:rule) { double(expression: "cron(0 0 * * ? *)") }
      let(:target) do
        double(
          cluster: cluster,
          definition: definition,
          container: "testContainer",
          commands: ["bundle", "exec", "bin/rails", "runner", "-e", "production", "Hoge.run"]
        )
      end
      let(:args) do
        %W(
          -l test
          --region us-east-1
          -f #{Pathname(__dir__) + "fixtures/schedule.rb"}
        )
      end

      before do
        allow(ElasticWhenever::Task::Rule).to receive(:fetch).with(kind_of(ElasticWhenever::Option)).and_return([rule])
        allow(ElasticWhenever::Task::Target).to receive(:fetch).with(kind_of(ElasticWhenever::Option), rule).and_return([target])
      end

      it "lists tasks" do
        expect {
          ElasticWhenever::CLI.run(args)
        }.to output(<<~OUTPUT).to_stdout
          cron(0 0 * * ? *) test wordpress:2 testContainer bundle exec bin/rails runner -e production Hoge.run

          ## [message] Above is your scheduled tasks.
          ## [message] Run `elastic_whenever --help` for more options.
        OUTPUT
      end
    end

    context "with print version mode" do
      it "prints version" do
        expect {
          ElasticWhenever::CLI.run(%w(-v))
        }.to output("Elastic Whenever v#{ElasticWhenever::VERSION}\n").to_stdout
      end
    end
  end
end

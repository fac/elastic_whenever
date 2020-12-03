set :cluster, 'ecs-test'
set :task_definition, 'example'
set :container, 'cron'

every :day, at: '03:00am' do
  runner 'Hoge.run'
end

every :day, at: '07:00am' do
  rake 'routes'
end

every '0 0 1 * *' do
  rake 'hoge:run'
  rake 'db:migrate'
  rake 'db:status'
  runner 'Fuga.run'
end

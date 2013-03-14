require "logger"
require "pp"
require "json"

class Exec
  attr_accessor :config

  def instance_id
    "i-testing"
  end

  def go(*args)
    @config = YAML.load(File.read(File.dirname(__FILE__) + "/../config/sauron.yml"))
    @logger = Logger.new(STDOUT)
    @mutex = Mutex.new

    if args.size == 0
      start!
    elsif args[0] == "register:instance"
      load_or_register_topics!
      register_instance_alarms!
    elsif args[0] == "deregister:instance"
      deregister_instance_alarms!
    else
      puts "unkonwn command #{args[0]}"
    end
  end

  def deregister_instance_alarms!
    cw = AWS::CloudWatch.new
    alarms = cw.client.describe_alarms

    to_delete = []

    alarms.data[:metric_alarms].each do |alarm|
      if alarm[:alarm_name] =~ /^sauron::#{instance_id}::/
        to_delete << alarm[:alarm_name]
      end
    end

    if to_delete.size > 0
      @logger.info "De-Register Alarms #{to_delete.inspect}"
      cw.alarms.delete(*to_delete)
    end
  end

  def register_instance_alarms!
    cw = AWS::CloudWatch.new

    @config[:watches].each do |watch|
      [:warning, :critical].each do |threshold|
        alarm_name = "sauron::#{instance_id}::#{watch[:name]}-#{threshold}"

        alarm = cw.alarms[alarm_name]

        unless alarm.exists?
          @logger.info "Register Alarm #{alarm_name}"

          cw.alarms.create(alarm_name, {
            namespace: @config[:namespace],
            metric_name: watch[:name],
            dimensions: [{
              :name => "InstanceId",
              :value => instance_id
            }],
            comparison_operator: "GreaterThanThreshold",
            evaluation_periods: 1,
            period: (@config[:alarm_periods][threshold] || 5) * 60,
            statistic: "Maximum",
            threshold: (threshold == :warning ? 0 : 1),
            insufficient_data_actions: (threshold == :critical ? @config[:arns] : []),
            actions_enabled: true,
            alarm_actions: @config[:arns],
            alarm_description: "sauron: #{watch.to_json}",
            unit: "None",
          })
        end
      end
    end
  end

  def unregister_alarms!
  end

  def start!
    @running = true

    namespace = @config[:namespace] || "sauron"

    @threads = @config[:watches].map do |w|
      thread_for_watch(namespace, w)
    end.compact

    @threads.each(&:join)

    if @killed_by
      @logger.error(@killed_by.to_s + " " + @killed_by.backtrace.join("\n"))
      raise @killed_by
    end
  end

  def kill!(e)
    @mutex.synchronize do
      @killed_by = e
    end
  end

  def thread_for_watch(namespace, watch)
    return nil if watch[:type] == "aws"
    raise "missing type" unless watch[:type]
    raise "missing name" unless watch[:name]

    Thread.new do 
      last_check = nil

      interval = watch[:interval] || 5
      cw = AWS::CloudWatch.new.client

      do_check = lambda do |&block|
        if !last_check || (Time.now - last_check > interval)
          last_check = Time.now
          block.call
        end
      end

      begin
        loop do
          running = true

          @mutex.synchronize do
            running = @running && !@killed_by
          end

          break unless running

          do_check.call do
            @logger.info "[CHECK] [#{instance_id}] #{watch[:name]}::#{watch[:type]} #{watch[:command] || ""}"

            case watch[:type].to_sym
            when :heartbeat
              cw.put_metric_data(
                namespace: namespace,
                metric_data: [{
                  metric_name: watch[:name],
                  dimensions: [{
                    :name => "InstanceId",
                    :value => instance_id
                  }],
                  value: 100,
                  unit: "Percent"
                }]
              )
            else
              raise "Unknown watch type #{watch[:type]}"
            end
          end

          sleep 1
        end
      rescue Exception => e
        kill!(e)
      end
    end
  end

  def shutdown!
    @mutex.synchronize do
      @running = false
    end
  end

  def load_or_register_topics!
    sns = AWS::SNS.new

    current_topics = sns.client.list_topics

    arns = []

    (@config[:topics] || ["sauron-alerts"]).each do |topic_name|
      current_topic = current_topics[:topics].find do |topic|
        topic[:topic_arn].split(/:/)[-1] == topic_name
      end

      if current_topic
        arns << current_topic[:topic_arn]
      else
        arn = sns.topics.create(topic_name).arn
        arns << arn

        @logger.info "Created Topic #{arn}"
      end
    end

    @config[:arns] = arns
  end
end

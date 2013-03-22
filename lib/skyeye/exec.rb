require "logger"
require "pp"
require "json"
require "open4"
require "open-uri"

module SkyEye
  class Exec
    attr_accessor :config

    def instance_id
      @instance_id ||= open("http://169.254.169.254/latest/meta-data/instance-id").read
    end

    def go(*args)
      config_file = ENV["SKYEYE_CONFIG_FILE"] || "/etc/skyeye.yml"

      unless File.exists?(config_file)
        puts "Missing #{config_file}. You can set the path to this file by exporting SKYEYE_CONFIG_FILE."
        return
      end

      @config = YAML.load(File.read(config_file))
      @logger = Logger.new(STDOUT)
      @mutex = Mutex.new

      if args.size == 0
        start!
      elsif args[0] == "register:instance"
        load_or_register_topics!
        register_instance_alarms!
      elsif args[0] == "deregister:instance"
        deregister_instance_alarms!
      elsif args[0] == "deregister:aws"
        deregister_aws_alarms!
      elsif args[0] == "register:aws"
        load_or_register_topics!
        register_aws_alarms!
      else
        puts "valid commands: [de]register:(aws|instance)"
      end
    end

    def deregister_instance_alarms!
      deregister_alarms_matching!(/^skyeye::instance::#{instance_id}::/)
    end

    def deregister_aws_alarms!
      @config[:watches].keys.each do |resource_type|
        unless resource_type == :instance
          deregister_alarms_matching!(/^skyeye::#{resource_type}::/)
        end
      end
    end

    def deregister_alarms_matching!(pattern)
      cw = AWS::CloudWatch.new
      alarms = cw.client.describe_alarms

      to_delete = []

      alarms.data[:metric_alarms].each do |alarm|
        if alarm[:alarm_name] =~ pattern
          to_delete << alarm[:alarm_name]
        end
      end

      if to_delete.size > 0
        @logger.info "De-Register Alarms #{to_delete.inspect}"
        cw.alarms.delete(*to_delete)
      end
    end

    def register_aws_alarms!
      @config[:watches].each do |resource_type, watches|
        dimension_values = dimension_values_for_resource_type(resource_type)
        register_alarms_for_watches!(resource_type, dimension_values) if dimension_values
      end
    end

    def dimension_values_for_resource_type(resource_type)
      values = []

      case resource_type
      when :elb
        AWS::ELB.new.load_balancers.each do |load_balancer|
          values << [{ name: "LoadBalancerName", value: load_balancer.name }]
        end
      when :rds
        AWS::RDS.new.db_instances.each do |db_instance|
          values << [{ name: "DBInstanceIdentifier", value: db_instance.db_instance_identifier }]
        end
      when :elasticache
        AWS::ElastiCache.new.client.describe_cache_clusters(show_cache_node_info: true).data[:cache_clusters].each do |cluster|
          cluster[:cache_nodes].each do |node|
            values << [{ name: "CacheClusterId", value: cluster[:cache_cluster_id] },
                       { name: "CacheNodeId", value: node[:cache_node_id] }]
          end
        end
      when :sqs
        AWS::SQS.new.queues.each do |queue|
          values << [{ name: "QueueName", value: queue.arn.split(/:/)[-1] }]
        end
      end

      values
    end
    
    def namespace_for_resource_type(resource_type)
      case resource_type
      when :instance
        return "AWS/EC2"
      when :elb
        return "AWS/ELB"
      when :rds
        return "AWS/RDS"
      when :elasticache
        return "AWS/ElastiCache"
      when :sqs
        return "AWS/SQS"
      end
    end

    def register_instance_alarms!
      cw = AWS::CloudWatch.new

      watches = @config[:watches][:instance]
      dimension_values = [[{ name: "InstanceId", value: instance_id }]]

      register_alarms_for_watches!(:instance, dimension_values)
    end

    def register_alarms_for_watches!(resource_type, dimension_values)
      cw = AWS::CloudWatch.new

      dimension_values.each do |dimension_value|
        @config[:watches][resource_type].each do |watch|
          [:warning, :critical].each do |threshold|
            target = dimension_value.map { |v| v[:value] }.join("_")
            alarm_name = "skyeye::#{resource_type}::#{target}::#{watch[:name]}-#{threshold}"

            alarm = cw.alarms[alarm_name]

            unless alarm.exists?
              is_command = !!watch[:command]
              raise "Cannot specify command for non-instance watch" if is_command && resource_type != :instance

              if is_command || watch[threshold]
                @logger.info "Register Alarm #{alarm_name}"

                cw.alarms.create(alarm_name, {
                  namespace: is_command ? @config[:namespace] : namespace_for_resource_type(resource_type),
                  metric_name: watch[:name],
                  dimensions: dimension_value,
                  comparison_operator: watch[:comparison_operator] || "GreaterThanThreshold",
                  evaluation_periods: 1,
                  period: (watch[:period] || @config[:alarm_periods][threshold] || 5) * 60,
                  statistic: watch[:statistic] || "Maximum",
                  threshold: is_command ? (threshold == :warning ? 0 : 1) : watch[threshold],
                  insufficient_data_actions: (threshold == :critical && is_command ? @config[:arns] : []),
                  actions_enabled: true,
                  alarm_actions: @config[:arns],
                  alarm_description: "skyeye: #{watch.to_json}",
                })
              end
            end
          end
        end
      end
    end

    def start!
      @running = true
      @logger.info "SkyEye starting."

      namespace = @config[:namespace] || "skyeye"

      @threads = @config[:watches][:instance].map do |w|
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

              if watch[:command]
                command = watch[:command]
                message = nil

                status = Open4::popen4(command) do |pid, stdin, stdout, stderr|
                  message = "#{watch[:name]} :: #{stdout.readlines.join(" ").gsub(/\n/, " ").chomp}"
                end

                case status
                when 0
                  @logger.info message
                when 1
                  @logger.warn message
                when 2
                  @logger.error message
                else
                  @logger.warn message
                end

                cw.put_metric_data({
                  namespace: namespace,
                  metric_data: [{
                    metric_name: watch[:name],
                    dimensions: [{
                      :name => "InstanceId",
                      :value => instance_id
                    }],
                    value: status.exitstatus,
                    unit: "None"
                  }]
                })
              else
                raise "Missing command or aws id for watch #{watch[:name]}"
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

      (@config[:topics] || ["skyeye-alerts"]).each do |topic_name|
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
end

#! /usr/bin/env ruby
#
# The MIT License
#
# Copyright (c) 2013-2014 Pivotal Software, Inc.
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.
#

require 'rubygems'
require 'bundler/setup'
require 'newrelic_plugin'
require 'rabbitmq_manager'
require 'uri'

module NewRelic
  module RabbitMQPlugin
    class Agent < NewRelic::Plugin::Agent::Base
      agent_guid 'com.pivotal.newrelic.plugin.rabbitmq'
      agent_version '1.0.5'
      agent_config_options :management_api_url, :queues, :ssl_options, :debug
      agent_human_labels('RabbitMQ') do
        rmq_manager.overview["cluster_name"]
      end

      def poll_cycle
        if debug
          puts "[RabbitMQ] Debug Mode On: Metric data will not be sent to new relic"
        end

        @overview = rmq_manager.overview
        report_metric_check_debug 'Queued Messages/Ready', 'messages', queue_size_ready
        report_metric_check_debug 'Queued Messages/Unacknowledged', 'messages', queue_size_unacknowledged

        report_metric_check_debug 'Message Rate/Acknowledge', 'messages/sec', ack_rate
        report_metric_check_debug 'Message Rate/Confirm', 'messages/sec', confirm_rate
        report_metric_check_debug 'Message Rate/Deliver', 'messages/sec', deliver_rate
        report_metric_check_debug 'Message Rate/Publish', 'messages/sec', publish_rate
        report_metric_check_debug 'Message Rate/Return', 'messages/sec', return_unroutable_rate

        report_nodes
        report_queues

      rescue => e
        $stderr.puts "[RabbitMQ] Exception while processing metrics. Check configuration."
        $stderr.puts e.message
        $stderr.puts e.backtrace.inspect if debug
      end

      def report_metric_check_debug(metricname, metrictype, metricvalue)
        if debug
          puts("#{metricname}[#{metrictype}] : #{metricvalue}")
        else
          report_metric metricname, metrictype, metricvalue
        end
      end

      private

      def rmq_manager
        @rmq_manager ||= ::RabbitMQManager.new(management_api_url, ssl_options)
      end

      def queue_size_for(type = nil)
        totals_key = 'messages'
        totals_key << "_#{type}" if type

        queue_totals = @overview['queue_totals']
        if queue_totals.size == 0
          $stderr.puts "[RabbitMQ] No data found for queue_totals[#{totals_key}]. Check that queues are declared. No data will be reported."
        else
          queue_totals[totals_key] || 0
        end
      end

      def queue_size_ready
        queue_size_for 'ready'
      end

      def queue_size_unacknowledged
        queue_size_for 'unacknowledged'
      end

      def ack_rate
        rate_for 'ack'
      end

      def confirm_rate
        rate_for 'confirm'
      end

      def deliver_rate
        rate_for 'deliver'
      end

      def publish_rate
        rate_for 'publish'
      end

      def rate_for(type)
        msg_stats = @overview['message_stats']

        if msg_stats.is_a?(Hash)
          details = msg_stats["#{type}_details"]
          details ? details['rate'] : 0
        else
          0
        end
      end

      def return_unroutable_rate
        rate_for 'return_unroutable'
      end

      def report_nodes
        default_node_name = @overview['node']
        rmq_manager.nodes.each do |n|
          {
            'fd_used' => [:file_descriptors, 'File Descriptors'],
            'sockets_used' => [:sockets, 'Sockets'],
            'proc_used' => [:processes, 'Erlang Processes'],
            'mem_used' => [:bytes, 'Memory Used'],
          }.each do |key, categorized_path|
            category, *path = categorized_path
            report_metric_check_debug mk_path('Node', n['name'], *path), category.to_s, n[key]
            if n['name'] == default_node_name
              # Report the default node both with and without a name so that
              # it appears on the plugin dashboard.
              report_metric_check_debug mk_path('Node', *path), category.to_s, n[key]
            end
          end
        end
      end

      def report_queues
        rmq_manager.queues.each do |q|
          name = q['name']
          next if name.start_with?('amq.gen')
          if queues
            must_match = queues['include']
            next if must_match and not must_match.any? { |r| Regexp.new(r).match(name) }
            next if (queues['exclude'] || []).any? { |r| Regexp.new(r).match(name) }
          end
          {
            'messages' => [:message, 'Messages', 'Total'],
            'messages_ready' => [:message, 'Messages', 'Ready'],
            'consumers' => [:consumers, 'Consumers', 'Total'],
            'consumer_utilisation' => [:consumers, 'Consumers', 'Utilization'],
            'memory' => [:bytes, 'Memory'],
          }.each do |key, categorized_path|
            category, *path = categorized_path
            report_metric_check_debug mk_path('Queue', q['vhost'], name, *path), category.to_s, q[key]
          end
        end
      end

      def mk_path(*args)
        args.map { |a|
          a.gsub(/[\/%]/) { |c| URI.encode_www_form_component(c) }
        }.join "/"
      end
    end

    NewRelic::Plugin::Setup.install_agent :rabbitmq, self

    # Launch the agent; this never returns.
    NewRelic::Plugin::Run.setup_and_run if __FILE__ == $PROGRAM_NAME
  end
end

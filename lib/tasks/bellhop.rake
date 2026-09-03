# frozen_string_literal: true

namespace :bellhop do
  desc "Check everything that can be wrong before an agent will pair"
  task doctor: :environment do
    green, red, dim, bold, reset = "\e[32m", "\e[31m", "\e[2m", "\e[1m", "\e[0m"

    checks = Bellhop::Doctor.run
    puts
    checks.each do |check|
      mark = check.ok ? "#{green}✓#{reset}" : "#{red}✗#{reset}"
      puts "  #{mark} #{bold}#{check.name}#{reset}  #{check.detail}"
      puts "      #{dim}#{check.remedy}#{reset}" if check.remedy
    end
    puts

    exit 1 unless checks.all?(&:ok)
  end

  desc "Create an agent and print its pairing link"
  task :pair, [ :label ] => :environment do |_task, args|
    label = args[:label].presence or abort %(Usage: rails "bellhop:pair[Shipping Desk]")

    agent = Bellhop::Agent.provision(label: label)
    puts <<~MESSAGE

      Agent #{agent.label} created (bellhop.dev agent #{agent.remote_id}).

      Open this on the computer at that location:

        #{agent.pairing_link}

      Single use, and it expires. It contains a bearer credential, so treat it
      like one: do not paste it anywhere that outlives the pairing.

    MESSAGE
  end

  desc "Mint fresh credentials for agents expiring soon"
  task renew: :environment do
    result = Bellhop.renew!
    puts "renewed: #{result[:renewed].size}, failed: #{result[:failed].size}"
    result[:failed].each { |id, code| puts "  agent #{id}: #{code}" }
  end

  desc "Expire HTTP transport sessions that have stopped polling"
  task sweep: :environment do
    Bellhop::Session.sweep_expired
  end

  desc "List agents and their state"
  task agents: :environment do
    Bellhop::Agent.find_each do |agent|
      state = if !agent.paired? then "not paired"
      elsif agent.online? then "online"
      else "offline"
      end
      puts format("  %-6s %-22s %-12s %s", agent.id, agent.label, state, agent.capabilities.join(", "))
    end
  end
end

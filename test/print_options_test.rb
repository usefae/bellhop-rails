# frozen_string_literal: true

require "test_helper"

# Everything knowable without an agent fails at the call site; everything
# about a particular printer is left to the agent and its ack.
class PrintOptionsTest < ActiveSupport::TestCase
  test "refuses an unknown option key, naming it" do
    agent, _machine = paired

    error = assert_raises(Bellhop::AgentError) do
      agent.print(kind: "slip", format: :pdf, data: "x", options: { duplx: "long-edge" })
    end
    assert_match(/Unknown print option `duplx`/, error.message)
    assert_match(/copies, duplex, paper/, error.message)
  end

  test "refuses an option that does not apply to the format" do
    agent, _machine = paired

    error = assert_raises(Bellhop::AgentError) do
      agent.print(kind: "label", format: :zpl, data: "x", options: { paper: "Letter" })
    end
    assert_match(/`paper` option does not apply to zpl/, error.message)

    assert_raises(Bellhop::AgentError) do
      agent.print(kind: "label", format: :gif, data: "x", options: { duplex: "long-edge" })
    end
  end

  test "refuses a value outside its enum or range" do
    agent, _machine = paired

    [
      { copies: 0 }, { copies: 101 }, { copies: "2" },
      { duplex: "vertical" },
      { rotate: 45 }, { rotate: "90" },
      { nup: 3 },
      { color: "yes" },
      { dpi: 0 }
    ].each do |options|
      assert_raises(Bellhop::AgentError, options.inspect) do
        agent.print(kind: "slip", format: :pdf, data: "x", options: options)
      end
    end
  end

  test "refuses a malformed pages string" do
    agent, _machine = paired

    [ "7,1-4", "4-1", "1-4, 7", "0-3", "1-4,4", "1-4,2-9", "1-", "" ].each do |pages|
      error = assert_raises(Bellhop::AgentError, pages.inspect) do
        agent.print(kind: "slip", format: :pdf, data: "x", options: { pages: pages })
      end
      assert_match(/`pages` must be ascending/, error.message)
    end
  end

  test "accepts a well-formed pages string" do
    agent, machine = paired

    agent.print(kind: "slip", format: :pdf, data: "x", options: { pages: "1-4,7,9-12" })

    assert_equal "1-4,7,9-12", machine.printed.first[:options]["pages"]
  end

  test "refuses a printer the agent's last hello did not report" do
    agent, _machine = paired

    error = assert_raises(Bellhop::AgentError) do
      agent.reload.print(kind: "label", format: :zpl, data: "x", printer: "Payroll_HP")
    end
    assert_match(/has not shared a printer "Payroll_HP"/, error.message)
    assert_match(/Fake_ZP450, Fake_Office_Laser/, error.message)
  end

  test "refuses raw when the agent did not advertise print:raw" do
    agent, _machine = paired(capabilities: %w[print:zpl print:pdf])

    error = assert_raises(Bellhop::AgentError) do
      agent.reload.print(kind: "receipt", format: :raw, data: "\x1B@receipt")
    end
    assert_match(/does not advertise print:raw/, error.message)
  end

  test "an accepted job carries its printer and options on the wire" do
    agent, machine = paired

    job = agent.reload.print(
      kind: "slip", format: :pdf, data: "pdf-bytes",
      printer: "Fake_Office_Laser",
      options: { copies: 2, duplex: "long-edge", paper: "Letter", collate: true }
    )

    delivered = machine.printed.first
    assert_equal "Fake_Office_Laser", delivered[:printer]
    assert_equal(
      { "copies" => 2, "duplex" => "long-edge", "paper" => "Letter", "collate" => true },
      delivered[:options]
    )
    assert_equal "printed", job.reload.status
    assert_equal "Fake_Office_Laser", job.printer
    assert_equal 2, job.options["copies"]
  end

  test "raw prints when advertised, untouched, and takes copies" do
    agent, machine = paired

    agent.reload.print(kind: "receipt", format: :raw, data: "\x1B@receipt bytes",
                       printer: "Fake_ZP450", options: { copies: 3 })

    delivered = machine.printed.first
    assert_equal "raw", delivered[:format]
    assert_equal "\x1B@receipt bytes", delivered[:data]
    assert_equal({ "copies" => 3 }, delivered[:options])
  end

  test "a job that names nothing carries neither field" do
    agent, machine = paired

    agent.print(kind: "label", format: :zpl, data: "^XA^XZ")

    message = machine.received.first
    refute message.key?("printer")
    refute message.key?("options")
  end

  test "hello stores the printer inventory, capabilities included" do
    agent, _machine = paired
    agent.reload

    zebra = agent.printer("Fake_ZP450")
    assert_equal "Fake ZP450", zebra["name"]
    assert_equal false, zebra["capabilities"]["duplex"]
    assert_equal [ "w288h432" ], zebra["capabilities"]["papers"]
    assert_equal({ "label" => "Fake_ZP450", "document" => "Fake_Office_Laser" }, agent.default_printers)
  end

  test "queueing for an agent that has never connected checks nothing" do
    agent = provision

    job = agent.print(kind: "receipt", format: :raw, data: "x", printer: "Anything")

    assert_equal "pending", job.reload.status
    assert_equal "Anything", job.printer
  end
end

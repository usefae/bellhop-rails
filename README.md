# Bellhop for Rails

Print to the label printers and read the USB scales at a physical location,
from your Rails application. The connection runs from your server to the
machine at that location, and nothing sits in the middle of it.

You need an app on [bellhop.dev](https://bellhop.dev). That is where agents
are licensed and where your secret key comes from.

```bash
bundle add bellhop-rails
bin/rails generate bellhop:install
bin/rails db:migrate
bin/rails bellhop:doctor
```

The generator writes the initializer and the migration, and mounts the engine
at `/bellhop`. Two settings in the initializer matter.

`secret_key` is on your app's page on bellhop.dev. Keep it in credentials.

`public_url` is your application's public base URL. Its host is the **pairing
host**: it goes in every pairing link, every credential is bound to it, and
the agent compares it byte for byte. Pick it once. Changing it after agents
have paired means all of them re-pair. Your socket can live on another host;
the `transports` block in the claim response is for that.

Ruby 3.2 and Rails 7.2 or later.

## Using it

```ruby
# Add a location, then put the link in front of whoever is at the desk.
agent = Bellhop::Agent.provision(label: "Shipping Desk")
agent.pairing_link       # bellhop://pair?server=…&claim=…

agent.print(kind: "label", format: :zpl, data: zpl)

# Anything large goes by URL. The block runs once the job exists, so a
# signed URL can name it.
agent.print(kind: "packing_slip", format: :pdf) { |job| document_url(job, sig: sign(job)) }

# Name a printer, and say how, when the desk's default is not what you want.
agent.print(
  kind: "packing_slip", format: :pdf,
  printer: "Office_HP_LaserJet",
  options: { copies: 2, duplex: "long-edge", paper: "Letter" }
) { |job| document_url(job, sig: sign(job)) }

# What the desk shared in its most recent hello.
agent.printers
# => [{ "id" => "Office_HP_LaserJet", "name" => "Office HP LaserJet",
#       "capabilities" => { "papers" => ["Letter", "Legal", "A4"], "duplex" => true, ... } }]

# Hear back from it.
ActiveSupport::Notifications.subscribe("weight.bellhop") do |event|
  ShippingForm.fill(event.payload[:agent], grams: event.payload[:grams])
end

ActiveSupport::Notifications.subscribe("ack.bellhop") do |event|
  job = event.payload[:job]
  Rails.logger.warn("#{job.id} failed: #{job.error}") if job.status == "failed"
end
```

`kind` is yours; the agent never reads it. Formats are `zpl`, `pdf`, `gif`,
and `raw`. Raw delivers any byte stream to the queue untouched: ESC/POS
receipts, EPL, whatever your hardware speaks.

A job that names a `printer` goes to it, by the `id` from the agent's
inventory. A job that names none routes by format to the printer the operator
picked for labels or for documents. If the agent is offline the job stays
pending and goes out at its next handshake. Machines sleep overnight; that is
normal.

`options` is a closed set: `copies`, `duplex`, `paper`, `bin`, `dpi`,
`color`, `pages`, `rotate`, `fit`, `collate`, `nup`. An option you leave out
means whatever the printer does by default.

Anything the gem can check without an agent, it checks before sending, and
raises `Bellhop::AgentError` at your own line: a format the agent has not
advertised, a printer its last hello did not report, an option the protocol
does not define, an option that does not apply to the format, a value outside
its range, a malformed page range, an inline document over 50 MB. What only
the desk can know (does that laser printer hold Letter?) the agent checks
before printing and reports in the ack, with an `error_code` your code can
branch on.

## When it does not pair

```
$ bin/rails bellhop:doctor

  ✓ pairing host  deliver.example.com
  ✓ secret key    authenticated as "Deliver"
  ✓ plan          fleet, 34/100 agents
  ✓ scales        allowed on this plan
  ✓ signing keys  https://bellhop.dev publishes 2026-08
  ✓ cable adapter solid_cable
  ✓ transports    websocket and http
  ✓ poll budget   poll_seconds is 0, so no request is ever held
```

Every one of those failures looks the same from the outside. Start here.

## Transports

Both are mounted. The agent prefers the socket and falls back to HTTP by
itself after three failed upgrades, which is what gets a shipping desk behind
a corporate proxy working.

The socket is Action Cable's server with Action Cable's protocol stripped off.
The wire carries flat JSON: no subscription handshake, no channel identifier,
no JSON inside JSON, and no welcome message. What Action Cable provides is
connection lifecycle and a pubsub backplane, so a print created on one Puma
worker reaches a socket held by another. The engine runs its own
`ActionCable::Server::Base`, so your application's cable configuration is
untouched. Request forgery protection is off on that instance only. The agent
is a native application and sends no `Origin` header, and Action Cable
refuses a connection without one. There is no browser and no cookie in play,
so there is nothing to protect.

No Action Cable at all, as in an API-only or `--minimal` application? The
engine skips the socket route, advertises HTTP alone, and `doctor` says so.

### `poll_seconds` is 0 by default

Rails serves requests from a fixed Puma thread pool, three per worker out of
the box. A held poll occupies one thread for its whole duration. Three agents
on a 25 second poll would park every thread and your application would stop
serving.

At 0 the request returns at once, the agent settles into polling every 3
seconds, and a label comes out within 3 seconds of being created. Nobody
standing at a printer notices that. Raise it only after counting your
threads; `doctor` does the arithmetic against your agent count.

## Running more than one process

The socket needs a real pubsub adapter: `solid_cable` on a default Rails 8
app, or Redis. With the `async` adapter a print created by one worker cannot
reach a socket held by another, and `doctor` warns you. HTTP has no such
need. Its queue is a table row, so any process can write to it.

One caveat on `solid_cable`. It polls the database from every process, and
this gem subscribes one channel per connected agent, so the backplane itself
becomes database load as the fleet grows. It is fine to about a thousand
agents. Plan on Redis beyond that; `doctor` tracks your fleet size and says
when.

## Plan changes

Entitlements live in the credential and are read when it is minted. On its
own, a plan change waits for the next renewal. Renewal is automatic as agents
connect, and `rails bellhop:renew` sweeps on demand.

Register `https://deliver.example.com/bellhop/webhook` on your app's page on
bellhop.dev and the wait goes away. bellhop.dev calls when the plan changes,
the engine verifies the delivery against the published signing keys, and
every paired agent is pushed a credential with the new entitlements.
bellhop.dev also calls when an agent is removed there, and the engine retires
it here too: connection closed, row gone. There is no webhook secret to hold.
Behind it are `Bellhop.refresh!` and `Bellhop.retire_deactivated!`, which you
can also call by hand. Each runs from Active Job when your app has it and
inline when it does not.

## The admin

It is at the engine's mount point. It is open in development and refuses to
render anywhere else until you say who may see it:

```ruby
config.admin_authenticator = ->(controller) { controller.current_user&.admin? }
```

It lists your agents and can print to them or unpair them, so it should not
become reachable just because the engine is mounted.

It ships with its own standalone layout and a `<style>` block, in the same
plum and blush as bellhop.dev. Nothing to precompile, nothing that leaks into
the rest of your application. The fonts load from Google Fonts; delete that
`<link>` from the layout and the stacks fall back to Georgia and the system
sans.

To change how it looks, or to put it inside your own layout:

```bash
bin/rails generate bellhop:admin
```

That copies the controllers and views into your application, stylesheet
partial included. Rails resolves your paths ahead of an engine's, so from
then on yours render.

### The test label

The admin's **Label** button prints `Bellhop.test_label`: the Bellhop mark and
two lines of text, anchored to the top left corner so it comes out whole on
anything from 1.25in stock up. ZPL has no way to ask a printer how wide its
stock is, so the default never assumes a width.

When you know the width, say so in dots and the label is centred across it:

```ruby
Bellhop.test_label(width: 812)   # 4in at 203 dpi
```

## Testing

Printing to a real agent is the right way to check that a label comes out.
For CI, where no agent exists:

```ruby
require "bellhop/testing"

agent = Bellhop::Agent.provision(label: "Test")
agent = Bellhop::Testing::FakeAgent.claim(agent)

agent.print(kind: "label", format: :zpl, data: zpl)

assert_equal 1, agent.printed.size
assert_includes agent.printed.first[:data], "^XA"
```

`FakeAgent` speaks the protocol the way the real agent does. It deduplicates
by job id and answers `ping`. `fail_prints:` exercises your error path,
`capabilities:` exercises the gate on formats an agent cannot handle,
`printers:` shapes the inventory it advertises, and `default_printers:` sets
the role map. Each entry in `printed` carries the `printer` and `options` the
job named.

## What it will not do

**Validate inbound messages against the schemas.** Both sides ignore what
they do not recognise. That rule is the protocol's only forward-compatibility
mechanism, and enforcing schemas would break it.

**Log tokens.** Claim tokens, agent tokens, credentials, and the
`Authorization` header stay out of log lines. `bellhop:pair` prints a link
that nothing else records, because the link is the claim token.

**Redeliver on every `hello`.** A `hello` arrives mid-session whenever an
operator changes a printer. Re-sending outstanding jobs each time can outrun
the agent's deduplication ledger and print the same label several times. Only
the first `hello` on a connection redelivers. A reconnect is a new
connection, so at-least-once delivery still holds.

## Reference

The protocol reference at https://bellhop.dev/docs/protocol is normative.
Where this gem disagrees with it, the gem is wrong. The integration guide is
at https://bellhop.dev/docs.

MIT licence.

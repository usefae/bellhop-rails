# Changelog

## Unreleased

- The webhook acts only on deliveries that name this app. The publishable key
  is read from bellhop.dev on the first delivery, or set with
  `config.publishable_key`.
- A delivery that lands twice is acted on once, and a burst of deliveries
  enqueues one refresh (or one retire) rather than one job each.
- The published signing keys are fetched again from time to time, so a key
  withdrawn from the set stops verifying webhooks here.

## 1.0.0

First release.

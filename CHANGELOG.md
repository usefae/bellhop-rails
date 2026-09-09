# Changelog

## Unreleased

- The webhook acts only on deliveries that name this app. The publishable key
  is read from bellhop.dev on the first delivery, or set with
  `config.publishable_key`.
- A burst of deliveries enqueues one refresh (or one retire) rather than one
  job each. A delivery whose job the queue will not take is answered with a
  503 so bellhop.dev redelivers, never with a 202 and no job.
- The published signing keys are fetched again from time to time, so a key
  withdrawn from the set stops verifying webhooks here.

## 1.0.0

First release.

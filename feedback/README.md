# Feedback

> [!WARNING]
> Feedback is a 1.1 development scaffold. HR department sync and a dedicated
> Feedback bot token are fine-tunes for later.

Staff send private Telegram feedback (positive/negative, anonymous defaults,
department including Board, optional board notify). Intercom’s poller forwards
DMs to this module so one bot token still works.

Documentation: [Feedback on the Con Services site](https://aglelectronics.github.io/con-services/modules/feedback/).

## Run locally

```sh
docker compose --profile intercom up --build feedback-frontend intercom-frontend
```

Open <http://localhost:3014> or <https://feedback.conservices.test>.

DM the staff bot `/feedback` and follow the prompts.

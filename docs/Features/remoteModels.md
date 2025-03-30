# Remote Models

To configure a remote model provider during setup, click `Use model server`.

To configure a remote model provider after setup, navigate to `Sidekick` -> `Settings` -> `Inference`, then scroll down to the `Remote Model` section.

## Configuring an Endpoint

Sidekick works with OpenAI compatible APIs.

![Remote Models](../img/Docs Images/Features/Remote Models/remoteModelSettingsTop.png)

To configure an endpoint, get the endpoint URL from your provider, and enter all components that precedes `/v1`. For example, if the URL is `https://api.openai.com/v1`, enter `https://api.openai.com/` into the `Endpoint` field.

Next, enter your API key. This is encrypted with a key securely stored in your keychain.

## Selecting Models

You can choose 2 remote models, a main model and a worker model. Specified model names **must** be the same as that listed in your model provider's API documentation.

![Remote Models](../img/Docs Images/Features/Remote Models/remoteModelSettingsBottom.png)

### Main Model

This is the main model that powers most work in Sidekick, such as chat, most tools and more.

### Worker Model

The worker model is used for simple tasks that demand speed and responsiveness, but can accept trade-offs in quality. This includes automatic conversation titles generation and commands in Inline Writing Assistant.

Ideally, a worker model should be fast and cheap to run. As a result, reasoning models are not recommended.
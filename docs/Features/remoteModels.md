# Remote Models

To configure a remote model provider during setup, click `Use model server`.

To configure a remote model provider after setup, navigate to `Sidekick` -> `Settings` -> `Inference`, then scroll down to the `Remote Model` section.

## Configuring an Endpoint

Sidekick works with OpenAI compatible APIs.

![Remote Models](../img/Docs Images/Features/Remote Models/remoteModelSettingsTop.png)

To configure an endpoint, get the endpoint URL from your provider, and enter all components until `/v1`. For example, if you are using the OpenAI API, enter `https://api.openai.com/v1/` into the `Endpoint` field.

Common endpoints:

Aliyun Bailian (China): `https://dashscope.aliyuncs.com/compatible-mode/v1`

Anthropic: `https://api.anthropic.com/v1`

DeepSeek: `https://api.deepseek.com/v1`

Google AI Studio: `https://generativelanguage.googleapis.com/v1beta`

Groq: `https://api.groq.com/openai/v1`

LM Studio: `http://localhost:1234/v1`

Mistral: `https://api.mistral.ai/v1`

Ollama: `http://localhost:11434/v1`

OpenAI: `https://api.openai.com/v1`

OpenRouter: `https://openrouter.ai/api/v1`

Next, enter your API key. This is encrypted with a key securely stored in your keychain.

## Selecting Models

You can choose 2 remote models, a main model and a worker model. Specified model names **must** be the same as that listed in your model provider's API documentation.

![Remote Models](../img/Docs Images/Features/Remote Models/remoteModelSettingsBottom.png)

### Main Model

This is the main model that powers most work in Sidekick, such as chat, most tools and more.

### Worker Model

The worker model is used for simple tasks that demand speed and responsiveness, but can accept trade-offs in quality. This includes automatic conversation titles generation and commands in Inline Writing Assistant.

Ideally, a worker model should be fast and cheap to run. As a result, reasoning models are not recommended.
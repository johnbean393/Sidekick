# Local Models

## Adding a Model

To add a local model, navigate to `Sidekick` -> `Settings` -> `Inference` -> `Models` ,then click the `Manage` button to the right of the current model name.

![Local Models](../../img/Docs Images/Features/Local Models/speculativeDecodingSupport.png)

If you have already downloaded a `GGUF` model, click the `Add Model` button and select the `GGUF` model you have downloaded.

![Local Models](../../img/Docs Images/Features/Local Models/modelSelector.png)

If you are looking for a model, click the `Download Model` button. This will open a new window where you can select the model you want to download.

![Local Models](../../img/Docs Images/Features/Local Models/modelLibrary.png)

## Using Speculative Decoding

Speculative decoding is a technique that speeds up the inference process by running a smaller "draft model" in parallel with the main model.

To enable speculative decoding, flip the toggle in `Sidekick` -> `Settings` -> `Inference`.

![Local Models](../../img/Docs Images/Features/Local Models/speculativeDecodingSupport.png)

## Selecting a Model

You can choose 3 local models, a main model, a worker model, and a draft model for speculative decoding. 

To select a model, navigate to `Sidekick` -> `Settings` -> `Inference` -> `Models`, then click the `Manage` button to the right of the model's name.

![Local Models](../../img/Docs Images/Features/Local Models/speculativeDecodingSupport.png)

### Main Model

This is the main model that powers most work in Sidekick, such as chat, most tools and more.

In addition to Sidekick Settings, the local model can also be selected from the main window. Click the brain icon on the right hand side of the toolbar, and a menu will appear with a list of local models. Click on a model's name to select it.

![Local Models](../../img/Docs Images/Features/Local Models/modelToolbarMenu.png)

### Worker Model

The worker model is used for simple tasks that demand speed and responsiveness, but can accept trade-offs in quality. This includes automatic conversation titles generation and commands in Inline Writing Assistant.

Ideally, a worker model should be fast and cheap to run. As a result, reasoning models are not recommended.

### Draft Model

The draft model is used for speculative decoding. It should be in the same family as the main model, but with dramatically fewer parameters. This draft model **must** share the same tokenizer as the main model.
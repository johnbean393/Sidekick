# Local Models

## Adding a Model

To add a local model, navigate to `Sidekick` -> `Settings` -> `Inference`.

Click the `Manage` button to the right of the current model name.

![Local Models](../img/Docs Images/Features/Local Models/speculativeDecodingSupport.png)

If you have already downloaded a `GGUF` model, click the `Add Model` button and select the `GGUF` model you have downloaded.

![Local Models](../img/Docs Images/Features/Local Models/modelSelector.png)

If you are looking for a model, click the `Download Model` button. This will open a new window where you can select the model you want to download.

![Local Models](../img/Docs Images/Features/Local Models/modelLibrary.png)

## Using Speculative Decoding

Speculative decoding is a technique that speeds up the inference process by running a smaller "draft model" in parallel with the main model. This draft model **MUST** share the same tokenizer as the main model.

To enable speculative decoding, flip the toggle in `Sidekick` -> `Settings` -> `Inference`.

![Local Models](../img/Docs Images/Features/Local Models/speculativeDecodingSupport.png)

## Selecting a Model

To change the local model being used, click the brain icon on the right hand side of the toolbar. A menu will appear with a list of local models. Click on a model's name to select it.

![Local Models](../img/Docs Images/Features/Local Models/modelToolbarMenu.png)
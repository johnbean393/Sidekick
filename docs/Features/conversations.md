# Conversations

Conversations in Sidekick are the basic grouping unit for a series of related messages with the chatbot.

## Working with Messages

### Copying Message Content

To copy the content of a message, click the copy button above the message content. This will copy the content to the clipboard with Markdown formatting applied to the text.

![Conversations](../img/Docs Images/Features/Conversations/copyRaw.png)

To copy the raw message content with Markdown formatting syntax, click the three dots next to the copy button, then select `Copy Raw Markdown`.

### Read Response

To read Sidekick's response out loud, click the speaker button above the message content. Sidekick will read the response out. If you want to stop, click the speaker button again.

![Conversations](../img/Docs Images/Features/Conversations/chatSettings.png)

To change the voice used, go to `Settings` -> `Chat` -> `Voice` and select a voice.

## Reasoning Model Support

Sidekick supports a variety of reasoning models, including Alibaba Cloud's QwQ-32B and DeepSeek's DeepSeek-R1.

![Conversations](../img/Docs Images/Features/Conversations/reasoningModelSupport.png)

Click the purple header labeled `Reasoning Process` to hide and show the reasoning process.

## Function Calling

Sidekick can call functions to boost the mathematical and logical capabilities of models, and to execute actions. Functions are called sequentially in a loop until a result is obtained.

For example, when asking Sidekick to reverse a string or do arithmetic operation, it runs tools, then presents the result.

![Conversations](../img/Docs Images/Features/Conversations/functionCalling.png)

To view details for each function call, click the down arrow on the right.

![Conversations](../img/Docs Images/Features/Conversations/functionsToggle.png)

Code Interpreter is enabled by default if a remote model is used, but can be disabled in `Settings` -> `Chat` -> `Use Functions`.

## Advanced Markdown Rendering

Markdown is rendered beautifully in Sidekick.

### LaTeX

Sidekick offers native LaTeX rendering for mathematical equations.

![Conversations](../img/Docs Images/Features/Conversations/latexRendering1.png)

![Conversations](../img/Docs Images/Features/Conversations/latexRendering2.png)

### Data Visualization

Visualizations are automatically generated for tables when appropriate, with a variety of charts available, including bar charts, line charts and pie charts.

![Conversations](../img/Docs Images/Features/Conversations/dataVisualization1.png)

Charts can be dragged and dropped into third party apps.

![Conversations](../img/Docs Images/Features/Conversations/dataVisualizationDrag.png)

### Code

Code is beautifully rendered with syntax highlighting, and can be exported or copied at the click of a button.

![Conversations](../img/Docs Images/Features/Conversations/codeExport.png)
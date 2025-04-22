# Conversations

Conversations in Sidekick are the basic grouping unit for a series of related messages with the chatbot.

## Working with Messages

### Copying Message Content

To copy the content of a message, click the copy button above the message content. This will copy the content to the clipboard with Markdown formatting applied to the text.

![Conversations](../../img/Docs Images/Features/Conversations/copyRaw.png)

To copy the raw message content with Markdown formatting syntax, click the three dots next to the copy button, then select `Copy Raw Markdown`.

### Read Response

To read Sidekick's response out loud, click the speaker button above the message content. Sidekick will read the response out. If you want to stop, click the speaker button again.

![Conversations](../../img/Docs Images/Features/Conversations/chatSettings.png)

To change the voice used, go to `Settings` -> `Chat` -> `Voice` and select a voice.

## Reasoning Model Support

Sidekick supports a variety of reasoning models, including Alibaba Cloud's QwQ-32B and DeepSeek's DeepSeek-R1.

![Conversations](../../img/Docs Images/Features/Conversations/reasoningModelSupport.png)

Click the purple header labeled `Reasoning Process` to hide and show the reasoning process.

## Function Calling

Sidekick can call functions to boost the mathematical and logical capabilities of models, and to execute actions. Functions are called sequentially in a loop until a result is obtained.

For example, when asking Sidekick to reverse a string or do arithmetic operation, it runs tools, then presents the result.

![Conversations](../../img/Docs Images/Features/Conversations/functionCalling.png)

When telling Sidekick to draft an invitation email for a birthday celebration to my friend Jean, Sidekick finds my birthday and Jean's email address from my contacts book, and creates a draft in my default email client. 

![Screenshot](../../img/Docs Images/Features/Conversations/functionCallingDraftEmail.png)

To view details for each function call, click the down arrow on the right.

![Conversations](../../img/Docs Images/Features/Conversations/functionsToggle.png)

Code Interpreter is enabled by default if a remote model is used, but can be disabled in `Settings` -> `Chat` -> `Use Functions`.

## Memory

Sidekick can now remember helpful information between conversations, making its responses more relevant and personalized. Whether you're typing, speaking, or generating images in Sidekick, it can recall details and preferences you’ve shared and use them to tailor its responses. The more you use it, the more useful it becomes, and you’ll start to notice improvements over time.

For example, I might tell Sidekick that I am a beginner in Python trying to create my own version of Tetris.

![Conversations](../../img/Docs Images/Features/Conversations/memoryRemember.png)

When I ask it about `pygame` alternatives, it makes recommendations based on my current project, Tetris.

![Conversations](../../img/Docs Images/Features/Conversations/memoryUse.png)

## Advanced Markdown Rendering

Markdown is rendered beautifully in Sidekick.

### LaTeX

Sidekick offers native LaTeX rendering for mathematical equations.

![Conversations](../../img/Docs Images/Features/Conversations/latexRendering1.png)

![Conversations](../../img/Docs Images/Features/Conversations/latexRendering2.png)

### Data Visualization

Visualizations are automatically generated for tables when appropriate, with a variety of charts available, including bar charts, line charts and pie charts.

![Conversations](../../img/Docs Images/Features/Conversations/dataVisualization1.png)

Charts can be dragged and dropped into third party apps.

![Conversations](../../img/Docs Images/Features/Conversations/dataVisualizationDrag.png)

### Code

Code is beautifully rendered with syntax highlighting, and can be exported or copied at the click of a button.

![Conversations](../../img/Docs Images/Features/Conversations/codeExport.png)
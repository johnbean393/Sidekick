<h1 align="center">
  <p align="center">
    <img src="https://raw.githubusercontent.com/johnbean393/Sidekick/refs/heads/main/Docs%20Images/appIcon.png" alt="Logo" width = "200" height = "200">
  </p>
  <br />
  Sidekick
</h1>

<p align="center">
<img alt="Downloads" src="https://img.shields.io/github/downloads/johnbean393/Sidekick/total?label=Downloads" height=22.5>
<img alt="License" src="https://img.shields.io/github/license/johnbean393/Sidekick?label=License" height=22.5>
</p>

Chat with a local LLM that can respond with information from your files, folders and websites on your Mac without installing any other software. All conversations happen offline, and your data stays secure. Sidekick is a <strong>local first</strong> application –– with a built in inference engine for local models, while accommodating OpenAI compatible APIs for additional model options.

Sidekick supports modern GGUF local models such as Qwen3.5 out of the box through its built-in `llama.cpp` backend.

![Screenshot](https://raw.githubusercontent.com/johnbean393/Sidekick/refs/heads/main/Docs%20Images/demoScreenshot.png)

## Example Use

Let’s say you're collecting evidence for a History paper about interactions between Aztecs and Spanish troops, and you’re looking for text about whether the Aztecs used captured Spanish weapons.

![Screenshot](https://raw.githubusercontent.com/johnbean393/Sidekick/refs/heads/main/Docs%20Images/Features/Experts/demoHistoryScreenshot.png)

Here, you can ask Sidekick, “Did the Aztecs use captured Spanish weapons?”, and it responds with direct quotes with page numbers and a brief analysis.

![Screenshot](https://raw.githubusercontent.com/johnbean393/Sidekick/refs/heads/main/Docs%20Images/Features/Experts/demoHistorySource.png)

To verify Sidekick’s answer, just click on the references displayed below Sidekick’s answer, and the academic paper referenced by Sidekick immediately opens in your viewer.

## Features

Read more about Sidekick's features and how to use them [here](https://johnbean393.github.io/Sidekick/).

### Resource Use

Sidekick accesses files, folders, and websites from your experts, which can be individually configured to contain resources related to specific areas of interest. Activating an expert allows Sidekick to fetch and reference materials as needed.

Because Sidekick uses RAG (Retrieval Augmented Generation), you can theoretically put unlimited resources into each expert, and Sidekick will still find information relevant to your request to aid its analysis.

For example, a student might create the experts `English Literature`, `Mathematics`, `Geography`, `Computer Science` and `Physics`. In the image below, he has activated the expert `Computer Science`.

![Screenshot](https://raw.githubusercontent.com/johnbean393/Sidekick/refs/heads/main/Docs%20Images/Features/Experts/demoExpertUse.png)

Users can also give Sidekick access to files just by dragging them into the input field.

![Screenshot](https://raw.githubusercontent.com/johnbean393/Sidekick/refs/heads/main/Docs%20Images/Features/Conversations/demoTemporaryResource.png)

Sidekick can even respond with the latest information using **web search**, speeding up research.

![Screenshot](https://raw.githubusercontent.com/johnbean393/Sidekick/refs/heads/main/Docs%20Images/Features/Web%20Search/webSearch.png)

### Bring Your Own API Key

In addition to its core local-first capabilities, Sidekick allows you to bring your own key for OpenAI compatible APIs. This allows you to tap into additional remote models while still preserving a primarily local-first workflow.

Sidekick ships with built-in presets for popular providers, including **OpenAI**, **Anthropic**, **Google AI Studio**, **DeepSeek**, **Groq**, **MiniMax**, **Mistral**, **xAI**, and more — just select a provider and enter your API key to get started.

### Function Calling

Sidekick can call functions to boost the mathematical and logical capabilities of models, and to execute actions. Functions are called sequentially in a loop until a result is obtained.

For example, when asking Sidekick to calculate Q3 2025 financial metrics for Nvidia, it makes **27** tool calls, saves the CSV file and presents the results.

![Screenshot](https://raw.githubusercontent.com/johnbean393/Sidekick/refs/heads/main/Docs%20Images/Features/Function%20Calling/functionCallingFinancialMetrics.png)

When telling Sidekick to draft an invitation email for a birthday celebration to my friend Jean, Sidekick finds my birthday and Jean's email address from my contacts book, and creates a draft in my default email client.

![Screenshot](https://raw.githubusercontent.com/johnbean393/Sidekick/refs/heads/main/Docs%20Images/Features/Function%20Calling/functionCallingDraftEmail.png)

This enables agents running fully locally.

### Deep Research

Deep Research is a specific agent implemented in Sidekick to handle long horizon, multi-step research tasks.

![Screenshot](https://raw.githubusercontent.com/johnbean393/Sidekick/refs/heads/main/Docs%20Images/Features/Deep%20Research/deepResearchProgress.png)

Specify a research topic, and let Sidekick do the rest –– reading 50-80 webpages, and synthesizing information to prepare a research report.

![Screenshot](https://raw.githubusercontent.com/johnbean393/Sidekick/refs/heads/main/Docs%20Images/Features/Deep%20Research/deepResearchReport.png)

### Memory

Sidekick can now remember helpful information between conversations, making its responses more relevant and personalized. Whether you're typing, speaking, or generating images in Sidekick, it can recall details and preferences you’ve shared and use them to tailor its responses. The more you use it, the more useful it becomes, and you’ll start to notice improvements over time.

For example, I might tell Sidekick that I am a beginner in Python trying to create my own version of Tetris.

![Screenshot](https://raw.githubusercontent.com/johnbean393/Sidekick/refs/heads/main/Docs%20Images/Features/Memory/memoryRemember.png)

When I ask it about `pygame` alternatives, it makes recommendations based on my current project, Tetris.

![Screenshot](https://raw.githubusercontent.com/johnbean393/Sidekick/refs/heads/main/Docs%20Images/Features/Memory/memoryUse.png)

### Canvas

Create, edit and preview websites, code and other textual content using Canvas.

![Screenshot](https://raw.githubusercontent.com/johnbean393/Sidekick/refs/heads/main/Docs%20Images/Features/Canvas/canvasWebsite.png)

Select parts of the text, then prompt the chatbot to perform selective edits.

![Screenshot](https://raw.githubusercontent.com/johnbean393/Sidekick/refs/heads/main/Docs%20Images/Features/Canvas/canvasSelectiveEdit.png)

### Image Generation

Sidekick can generate images from text, allowing you to create visual aids for your work.

There are no buttons, no switches to flick, no `Image Generation` mode. Instead, a built-in CoreML model **automatically identifies** image generation prompts, and generates an image when necessary.

![Screenshot](https://raw.githubusercontent.com/johnbean393/Sidekick/refs/heads/main/Docs%20Images/Features/Image%20Generation/imageGeneration.png)

Image generation is available on macOS 15.2 or above, and requires Apple Intelligence.

### Advanced Markdown Rendering

Markdown is rendered beautifully in Sidekick.

#### LaTeX

Sidekick offers native LaTeX rendering for mathematical equations.

![Screenshot](https://raw.githubusercontent.com/johnbean393/Sidekick/refs/heads/main/Docs%20Images/Features/Conversations/latexRendering1.png)

![Screenshot](https://raw.githubusercontent.com/johnbean393/Sidekick/refs/heads/main/Docs%20Images/Features/Conversations/latexRendering2.png)

#### Data Visualization

Visualizations are automatically generated for tables when appropriate, with a variety of charts available, including bar charts, line charts and pie charts.

![Screenshot](https://raw.githubusercontent.com/johnbean393/Sidekick/refs/heads/main/Docs%20Images/Features/Conversations/dataVisualization1.png)

![Screenshot](https://raw.githubusercontent.com/johnbean393/Sidekick/refs/heads/main/Docs%20Images/Features/Conversations/dataVisualization2.png)

Charts can be dragged and dropped into third party apps.

#### Code

Code is beautifully rendered with syntax highlighting, and can be exported or copied at the click of a button.

![Screenshot](https://raw.githubusercontent.com/johnbean393/Sidekick/refs/heads/main/Docs%20Images/Features/Conversations/codeExport.png)

### Fast Generation

Sidekick uses `llama.cpp` as its inference backend, which is optimized to deliver lightning fast generation speeds on Apple Silicon. It also supports speculative decoding, which can further improve the generation speed.

![Screenshot](https://raw.githubusercontent.com/johnbean393/Sidekick/refs/heads/main/Docs%20Images/Features/Local%20Models/speculativeDecodingSupport.png)

Optionally, you can offload generation to speed up processing while extending the battery life of your MacBook.

![Screenshot](https://raw.githubusercontent.com/johnbean393/Sidekick/refs/heads/main/Docs%20Images/Features/Remote%20Models/remoteModelSettingsTop.png)

## Installation

### Requirements

- A Mac with Apple Silicon
- RAM ≥ 8 GB

### Via Homebrew

```bash
brew install --cask arcadi4/tap/sidekick
```

### Download and Setup

- Follow the guide [here](https://johnbean393.github.io/Sidekick/Markdown/gettingStarted/).

## Goals

The main goal of Sidekick is to make open, local, private, and contextually aware AI applications accessible to the masses.

Read more about our mission [here](https://johnbean393.github.io/Sidekick/Markdown/About/mission/).

## Developer Setup

### Requirements

- A Mac with Apple Silicon
- RAM ≥ 8 GB

### Developer Setup Instructions

1. Clone this repository.
1. Run `./setup.sh <TEAM_NAME>` to change the team in the Xcode project.
1. Open and run in Xcode.

## Contributing

Contributions are very welcome. Let's make Sidekick simple and powerful.

## Contact

Contact this repository's owner at <johnbean393@gmail.com>, or file an issue.

## Credits

This project would not be possible without the hard work of:

- psugihara and contributors who built [FreeChat](https://github.com/psugihara/FreeChat), which this project took heavy inspiration from
- Georgi Gerganov for [llama.cpp](https://github.com/ggerganov/llama.cpp)
- Alibaba for training Qwen 2.5
- Meta for training Llama 3
- Google for training Gemma 3

## Star History

<a href="https://star-history.dera.page/#johnbean393/Sidekick&type=Date">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://star-history.dera.page/svg?repos=johnbean393/Sidekick&type=Date&theme=dark" />
   <source media="(prefers-color-scheme: light)" srcset="https://star-history.dera.page/svg?repos=johnbean393/Sidekick&type=Date" />
   <img alt="Star History Chart" src="https://star-history.dera.page/svg?repos=johnbean393/Sidekick&type=Date" />
 </picture>
</a>

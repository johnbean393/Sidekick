<h1 align="center">
  <img src="https://raw.githubusercontent.com/johnbean393/Sidekick/refs/heads/main/README%20Images/appIcon.png" width = "200" height = "200">
  <br />
  Sidekick
</h1>

<p align="center">
<img alt="Downloads" src="https://img.shields.io/github/downloads/johnbean393/Sidekick/total?label=Downloads" height="22.5">
<img alt="License" src="https://img.shields.io/github/license/johnbean393/Sidekick?label=License" height="22.5">
</p>

Chat with a local LLM that can respond with information from your files, folders and websites on your Mac without installing any other software. All conversations happen offline, and your data stays secure. Sidekick is a <strong>local first</strong> application –– with a built in inference engine for local models, while accomodating OpenAI compatible APIs for additional model options.

![Screenshot](https://raw.githubusercontent.com/johnbean393/Sidekick/refs/heads/main/README%20Images/demoScreenshot.png)

## Example Use

Let’s say you're collecting evidence for a History paper about interactions between Aztecs and Spanish troops, and you’re looking for text about whether the Aztecs used captured Spanish weapons.

![Screenshot](https://raw.githubusercontent.com/johnbean393/Sidekick/refs/heads/main/README%20Images/demoHistoryScreenshot.png)

Here, you can ask Sidekick, “Did the Aztecs use captured Spanish weapons?”, and it responds with direct quotes with page numbers and a brief analysis.

![Screenshot](https://raw.githubusercontent.com/johnbean393/Sidekick/refs/heads/main/README%20Images/demoHistorySource.png)

To verify Sidekick’s answer, just click on the references displayed below Sidekick’s answer, and the academic paper referenced by Sidekick immediately opens in your viewer.

## Features

### Resource Use

Sidekick accesses files, folders, and websites from your experts, which can be individually configured to contain resources related to specific areas of interest. Activating an expert allows Sidekick to fetch and reference materials as needed.

Because Sidekick uses RAG (Retrieval Augmented Generation), you can theoretically put unlimited resources into each expert, and Sidekick will still find information relevant to your request to aid its analysis.

For example, a student might create the experts `English Literature`, `Mathematics`, `Geography`, `Computer Science` and `Physics`. In the image below, he has activated the expert `Computer Science`.

![Screenshot](https://raw.githubusercontent.com/johnbean393/Sidekick/refs/heads/main/README%20Images/demoExpertUse.png)

Users can also give Sidekick access to files just by dragging them into the input field.

![Screenshot](https://raw.githubusercontent.com/johnbean393/Sidekick/refs/heads/main/README%20Images/demoTemporaryResource.png)

Sidekick can even respond with the latest information using **web search**, speeding up research.

![Screenshot](https://raw.githubusercontent.com/johnbean393/Sidekick/refs/heads/main/README%20Images/webSearch.png)

### Bring Your Own API Key

In addition to its core local-first capabilities, Sidekick now offers an option to bring your own key for OpenAI compatible APIs. This allows you to tap into additional remote models while still preserving a primarily local-first workflow.

### Reasoning Model Support

Sidekick supports a variety of reasoning models, including Alibaba Cloud's QwQ-32B and DeepSeek's DeepSeek-R1.

![Screenshot](https://raw.githubusercontent.com/johnbean393/Sidekick/refs/heads/main/README%20Images/reasoningModelSupport.png)

### Code Interpreter

Sidekick uses a code interpreter to boost the mathematical and logical capabilities of models. 

Since small models are much better at writing code than doing math, having it write the code, execute it, and present the results dramatically increases trustworthiness of answers.

![Screenshot](https://raw.githubusercontent.com/johnbean393/Sidekick/refs/heads/main/README%20Images/codeInterpreter.png)

### Image Generation

Sidekick can generate images from text, allowing you to create visual aids for your work. 

There are no buttons, no switches to flick, no `Image Generation` mode. Instead, a built-in CoreML model **automatically identifies** image generation prompts, and generates an image when necessary.

![Screenshot](https://raw.githubusercontent.com/johnbean393/Sidekick/refs/heads/main/README%20Images/imageGeneration.png)

Image generation is available on macOS 15.2 or above, and requires Apple Intelligence.

### Inline Writing Assistant

Press `Command + Control + I` to access Sidekick's inline writing assistant. For example, use the `Answer Question` command to do your homework without leaving Microsoft Word!

![Screenshot](https://raw.githubusercontent.com/johnbean393/Sidekick/refs/heads/main/README%20Images/inlineWritingAssistant.png)

### Advanced Markdown Rendering

Markdown is rendered beautifully in Sidekick.

#### LaTeX

Sidekick offers native LaTeX rendering for mathematical equations.

![Screenshot](https://raw.githubusercontent.com/johnbean393/Sidekick/refs/heads/main/README%20Images/latexRendering1.png)

![Screenshot](https://raw.githubusercontent.com/johnbean393/Sidekick/refs/heads/main/README%20Images/latexRendering2.png)

#### Data Visualization

Visualizations are automatically generated for tables when appropriate, with a variety of charts available, including bar charts, line charts and pie charts.

![Screenshot](https://raw.githubusercontent.com/johnbean393/Sidekick/refs/heads/main/README%20Images/dataVisualization1.png)

![Screenshot](https://raw.githubusercontent.com/johnbean393/Sidekick/refs/heads/main/README%20Images/dataVisualization2.png)

Charts can be dragged and dropped into third party apps.

#### Code

Code is beautifully rendered with syntax highlighting, and can be exported or copied at the click of a button.

![Screenshot](https://raw.githubusercontent.com/johnbean393/Sidekick/refs/heads/main/README%20Images/codeExport.png)

### Toolbox

Use **Tools** in Sidekick to supercharge your workflow.

#### Detector

Use Detector to evaluate the AI percentage of text, and use provided suggestions to rewrite AI content.

![Screenshot](https://raw.githubusercontent.com/johnbean393/Sidekick/refs/heads/main/README%20Images/detectorEvaluationResults.png)

#### Diagrammer

![Screenshot](https://raw.githubusercontent.com/johnbean393/Sidekick/refs/heads/main/README%20Images/diagrammerPrompt.png)

Diagrammer allows you to swiftly generate intricate relational diagrams all from a prompt. Take advantage of the integrated preview and editor for quick edits.

![Screenshot](https://raw.githubusercontent.com/johnbean393/Sidekick/refs/heads/main/README%20Images/diagrammerPreviewEditor.png)

#### Slide Studio

![Screenshot](https://raw.githubusercontent.com/johnbean393/Sidekick/refs/heads/main/README%20Images/slideStudioPrompt.png)

Instead of making a PowerPoint, just write a prompt. Use AI to craft 10-minute presentations in just 5 minutes.

![Screenshot](https://raw.githubusercontent.com/johnbean393/Sidekick/refs/heads/main/README%20Images/slideStudioPreviewEditor.png)

Export to common formats like PDF and PowerPoint.

![Screenshot](https://raw.githubusercontent.com/johnbean393/Sidekick/refs/heads/main/README%20Images/slideStudioExport.png)

### Fast Generation

Sidekick uses `llama.cpp` as its inference backend, which is optimized to deliver lightning fast generation speeds on Apple Silicon. It also supports speculative decoding, which can further improve the generation speed.

Optionally, you can offload generation to speed up processing while extending the battery life of your MacBook.

![Screenshot](https://raw.githubusercontent.com/johnbean393/Sidekick/refs/heads/main/README%20Images/speculativeDecodingSupport.png)

![Screenshot](https://raw.githubusercontent.com/johnbean393/Sidekick/refs/heads/main/README%20Images/serverUse.png)

## Installation

**Requirements**
- A Mac with Apple Silicon
- RAM ≥ 8 GB

**Download**
- Download the disk image from [Releases](https://github.com/johnbean393/Sidekick/releases/), and open it.

## Goals

The main goal of Sidekick is to make open, local, private models accessible to more people, and allow a local model to gain context from select files, folders, and websites.

Sidekick is a local-first native LLM application for macOS. Download it and ask your LLM a question without doing any configuration. Give the LLM access to your folders, files and websites with just 1 click, allowing it to reply with context.

- No config. Usable by people who haven't heard of models, prompts, or LLMs.
- Performance and simplicity over developer experience or features. Notes not Word, Swift not Electron.
- Local first. Core functionality works without an internet connection, but you have the option to leverage online models.
- No conversation tracking. Talk about whatever you want with Sidekick, just like Notes.
- Open source. What's the point of running local AI if you can't audit that it's actually running locally?
- Context aware. Understands and accesses your files, folders, and even content on the web.

## Developer Setup

**Requirements**
- A Mac with Apple Silicon
- RAM ≥ 8 GB

1. Clone this repository.
2. Run `./setup.sh` to change the team in the Xcode project and download and sign the `marp` binary.
   - The `marp` binary is required for building and must be signed to create presentations.
3. Open and run in Xcode.

## Contributing

Contributions are very welcome. Let's make Sidekick simple and powerful.

## Contact

Contact this repository's owner at johnbean393@gmail.com, or file an issue.

## Credits

This project would not be possible without the hard work of:

- psugihara and contributors who built [FreeChat](https://github.com/psugihara/FreeChat), which this project took heavy inspiration from
- Georgi Gerganov for [llama.cpp](https://github.com/ggerganov/llama.cpp)
- Alibaba for training Qwen 2.5
- Meta for training Llama 3
- Google for training Gemma 3

## Star History

<a href="https://star-history.com/#johnbean393/Sidekick&Date">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=johnbean393/Sidekick&type=Date&theme=dark" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=johnbean393/Sidekick&type=Date" />
   <img alt="Star History Chart" src="https://api.star-history.com/svg?repos=johnbean393/Sidekick&type=Date" />
 </picture>
</a>

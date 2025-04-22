# Experts

Experts are the primary way Sidekick taps into domain specific knowledge and gains context about you and your work.

## Creating an Expert

To create an expert, click on the menu in the center of the toolbar, then select `Manage Experts`.

![Experts](../../img/Docs Images/Features/Experts/manageExperts.png)

In the sheet that appears, click the `Add Expert` button, then click the new expert's name to start editing.

![Experts](../../img/Docs Images/Features/Experts/expertList.png)

## Editing an Expert

To edit an expert, click the expert's name. Here, you can edit the expert's:

1. Name
2. Symbol
3. Color
4. Resources
5. Web Search Mode
6. System Prompt

![Experts](../../img/Docs Images/Features/Experts/editExpert.png)

### Adding a Resource

Resources form the expert's *"repository of knowledge"*. When chatting with the expert activated, the expert's resources are searched for relevant information, which is given to the chatbot along with your prompt.

This allows the chatbot to reply with context and domain specific information from your files.

To add a resource, click the add button, then select the type of content you want to add.

1. Files / Folders
2. Website
3. Email (Apple Mail only)

Once the resource has been selected, Sidekick will to scan the resource and prepare it for search. Progress is displayed in the notifications section in the main window.

## Activating an Expert

To activate an expert, click on the menu in the center of the toolbar, then select the expert of your choice.

Alternatively, go to the menu bar, click on `File` -> `Experts`, then select an expert from the list.

![Experts](../../img/Docs Images/Features/Experts/selectExpertMenu.png)

## Using an Expert

Returning to the main chat window, ask a question!

![Experts](../../img/Docs Images/Features/Experts/expertPromptExamples.png)

Ideally, the question should include a clear, focused topic that Sidekick can search for in an expert's resources.

To control how many sources Sidekick will search and provide to the LLM, navigate to `Sidekick` -> `Settings` -> `Inference` -> `Resource Use`, and adjust the settings as desired. 

![Experts](../../img/Docs Images/Features/Experts/resourceUseSettings.png)

The more sources that are provided to the LLM, the more likely it is that the LLM will provide a correct answer. However, this will come at the cost of generation speed.

## Example Use

A student is writing a paper on the Spanish conquest of the Americas. 

She needs to find sources to support her writing, but she doesn't know where to start, as the 1000+ pages of sources are too much to sift through manually. 

This is made worse by the fact that her professor expects in-text citations, with page numbers included. How the hell is she supposed to remember the content in sources **and** the corresponding page numbers?

She creates a History expert in Sidekick, then asks for examples using the prompt `Did the Aztecs use different captured Spanish weapons? Respond with direct quotes and page numbers.`.

Sidekick searches through her papers and locates quotes relevant to the query, then formulates it into an answer including direct quotes and page numbers.

![Experts](../../img/Docs Images/Features/Experts/demoHistoryScreenshot.png)

At the bottom of the message, references are included, which can be clicked to open the file referenced in Sidekick's response.

![Experts](../../img/Docs Images/Features/Experts/demoHistorySource.png)
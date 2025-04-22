# Web Search

Web search allows Sidekick to respond with up to date information, and reduces the chance of hallucinations, where the chatbot responds with false information.

## Configure Web Search

To configure web search, navigate to `Sidekick` -> `Settings` -> `Retrieval` -> `Web Search`.

![Web Search](../../img/Docs Images/Features/Web Search/webSearchSettings.png)

### DuckDuckGo

Web search is configured to use DuckDuckGo by default. No setup is required.

### Tavily

Select `Tavily` in the picker, then set an API key in the field below. Your API key will be encrypted with a key securely stored in your keychain.

You can create an API key by clicking the `Get an API Key` button, which will take you to [Tavily](https://app.tavily.com/home). 

![Web Search](../../img/Docs Images/Features/Web Search/tavilyApi.png)

You will need to sign up for an account and then create a new API key. Copy this key and paste it into the API key field in Sidekick's `Tavily Search` Settings.

Note that when web search is enabled, your prompt may be exposed to third parties such as Tavily.

## Using Web Search

Web search is activated in 2 ways.

If `Use Functions` is activated in Settings, Sidekick will automatically detect if web search is needed and call a function to search the web.

To force web search, you can also click the `Web Search` button in the prompt bar to toggle web search. For most queries, the model can use

## Example Use

Using web search allows Sidekick to respond using up to date information.

![Web Search](../../img/Docs Images/Features/Web Search/webSearch.png)

At the bottom of the message, references are included, which can be clicked to open the website referenced in Sidekick's response.
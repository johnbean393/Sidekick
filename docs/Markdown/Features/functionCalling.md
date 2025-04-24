# Function Calling

Sidekick can call functions to boost the mathematical and logical capabilities of models, and to execute actions. Functions are called sequentially in a loop until a result is obtained.

For example, when asking Sidekick to reverse a string or do arithmetic operation, it runs tools, then presents the result.

![Conversations](../../img/Docs Images/Features/Function Calling/functionCalling.png)

When telling Sidekick to draft an invitation email for a birthday celebration to my friend Jean, Sidekick finds my birthday and Jean's email address from my contacts book, and creates a draft in my default email client. 

![Screenshot](../../img/Docs Images/Features/Function Calling/functionCallingDraftEmail.png)

To view details for each function call, click the down arrow on the right.

![Conversations](../../img/Docs Images/Features/Function Calling/functionsToggle.png)

Function calling is enabled by default if a remote model is used, but can be disabled in `Settings` -> `Chat` -> `Use Functions`.
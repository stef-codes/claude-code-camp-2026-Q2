# What is the goal for week 1?

We want to build a baseline agent that has all common components for building any kind of agent. Things it should include: 

- a simple agentic loop
- a tool registry along with tools
- it should be able to handle multiple backends
- it should be able to produce logs 
- it should have a DSL so we can use the agent like an SDK
- it should have a global binary execution so we can interact via the CLI
- We should have a CLI option model
- it should manage context and compact messages when reaching out set limit
- it should haave its own configureation directory 

Other things: 
- log visualizer so we can better view the logs in our browser

## What should the baseline agent be able to do 
- It should be able to play the MUD

## What will it not be able to do?
It will have poor perception without memory or decision making. 

# What should we not do?
- Avoid using SDKs like AgentRouter 

## Technical Design considerations
- We will use REST APIs directly, this design choice is so we are understanding how simple it is to interact with managed APIs and how much they vary. 
- Some SDKs even official ones do not expose all features and so REST APIs will give us full access to feature sets
- We are using Ruby but the user can port it over to a different language
- We must use Ruby mudManager to interact with the MUD. 
- Ruby and python





 



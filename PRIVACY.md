# ConchTalk Privacy Policy

_Last updated: August 6, 2026_

ConchTalk ("the app", "we", "us") is an AI-assisted SSH client for iOS. We do not operate a ConchTalk backend for the app. There is no ConchTalk account or sign-in, subscription or billing system, managed AI/search gateway, request relay, or cloud sync. Data stays on your device or is sent directly from the app to the services and remote machines described below.

## Summary

- We do **not** sell your data or use it for advertising or cross-app/cross-site tracking.
- We do **not** require or provide a ConchTalk account, sign-in, subscription, or billing profile.
- Server configurations, chat history, memories, and system profiles are stored locally on your device.
- SSH passwords, private keys, and AI or optional web-search provider API keys are stored in the iOS Keychain.
- AI requests are sent directly to the AI endpoint you configure, under that provider's terms.
- When you enable web search, search queries are sent directly to the Brave, Exa, AnySearch, or Tavily service you select, under that provider's terms.
- SSH traffic is sent directly to remote machines you configure. There is no ConchTalk relay.
- To display a server's country, the public IP address resolved from its configured host is sent directly to the third-party Country API at `api.country.is`.

## Data the App Handles

### 1. On-device data

The app stores server connection details, chat history, memories, system profiles, settings, and local task state on your device. SSH passwords, private keys, AI API keys, and optional web-search provider API keys are protected by the iOS Keychain. We do not operate a service that receives or synchronizes this data.

### 2. AI processing

When you ask ConchTalk to perform a task, your prompt and relevant context are sent directly from the app to the AI endpoint you configured. ConchTalk does not provide a managed AI endpoint or fallback route. Your chosen provider may process and retain this data according to its own privacy policy and your agreement with that provider. Any account, subscription, or billing relationship used to obtain that provider's API access is between you and the provider, not ConchTalk.

### 3. SSH and direct-agent connections

The app connects directly to servers you configure. Commands, file contents, tool results, and direct-agent protocol messages may travel between your device and those servers as needed to carry out your instructions. ConchTalk does not relay or receive that traffic.

### 4. Optional web search

Web search is disabled by default. If you enable it and provide your own API key, search queries and search parameters are sent directly from the app to the Brave, Exa, AnySearch, or Tavily service you select. ConchTalk does not proxy or receive those requests or results through a ConchTalk server. The selected provider may process and retain this data according to its own privacy policy and your agreement with that provider. Search results used in a conversation may be included in the chat history stored on your device.

Provider privacy notices: [Brave Search API](https://api-dashboard.search.brave.com/privacy-policy), [Exa](https://exa.ai/privacy-policy), [AnySearch](https://www.anysearch.com/legal?type=privacy), and [Tavily](https://www.tavily.com/privacy).

### 5. IP country detection

To display a configured server's country, the app resolves the server hostname on your device and sends the resulting public IPv4 or IPv6 address directly to the third-party [Country API](https://country.is/) at `api.country.is` over HTTPS. The app requests only a two-letter country code. Private, reserved, and otherwise non-public addresses are not sent. This feature has no bundled local IP database or offline fallback, so the country may remain unknown if the API is unavailable. Country API may process the public IP address according to its own terms and privacy practices.

### 6. Apple platform services

The app may use local iOS features such as notifications, Live Activities, and on-device speech recognition. Any data handled by Apple platform services is governed by Apple's terms and privacy policy. ConchTalk does not use an account identifier to associate this activity with a backend profile.

## What We Do NOT Do

- We do not operate a ConchTalk account or sign-in system, subscription or billing service, user identity/profile backend, managed AI/search gateway, request relay, or cloud sync for the app.
- We do not use your data for advertising or marketing tracking.
- We do not share your data with data brokers or sell personal data.
- We do not access the contents of your remote servers beyond the direct connections and actions initiated through the app.

## Data Retention and Deletion

Local data remains on your device until you delete it or uninstall the app. When you delete supported records in the app, they may remain as locally stored deletion records for up to 30 days before physical cleanup. Copies contained in device backups are governed by your Apple backup settings. Data sent to your AI provider, selected web-search provider, Country API, or remote servers is retained according to the policies and configuration of those services, which ConchTalk does not control.

## Security

AI API keys, optional web-search provider API keys, SSH private keys, and SSH passwords are stored in the iOS Keychain. Country API requests use HTTPS; other network connections use the security mechanisms supported by your configured AI endpoint, selected web-search provider, and SSH server. You are responsible for choosing trusted providers, endpoints, servers, and credentials.

## Children

ConchTalk is not directed to children and is intended for general audiences.

## Changes

We may update this policy from time to time. Material changes will be reflected by updating the date at the top of this document.

## Contact

Questions about this policy or your data: open an issue at https://github.com/snana7mi/conchtalk/issues.

Source repository: https://github.com/snana7mi/conchtalk

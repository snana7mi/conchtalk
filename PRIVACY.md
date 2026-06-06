# ConchTalk Privacy Policy

_Last updated: June 7, 2026_

ConchTalk ("the app", "we", "us") is an AI-assisted SSH client for iOS. This policy explains what data the app handles, what leaves your device, and how it is protected. We designed ConchTalk to be privacy-first: most of your data stays on your device or on servers **you** own and control.

## Summary

- We do **not** sell your data, and we do **not** use it for advertising or cross-app/cross-site tracking.
- Your SSH credentials, server configurations, messages, and notes are stored **on your device**. They only leave your device if you enable optional Cloud Sync, and in that case they are **end-to-end encrypted** before upload — we cannot read them.
- We collect the minimum needed to run the app: a user identifier, purchase information (for subscriptions), and, if you opt into Cloud Sync, your encrypted user content.

## Data We Handle

### 1. On-device data (not collected by us)
SSH credentials (passwords and private keys), server connection details, chat history, memories, and system profiles are stored locally on your device. SSH private keys and passwords are kept in the iOS Keychain. This data is used solely to connect to and operate the remote servers **you** configure. It is never transmitted to us unless you enable Cloud Sync (see below).

### 2. User Content (only if you enable Cloud Sync — Pro feature)
If you enable Cloud Sync, your servers, messages, SSH keys, memories, and system profiles are synced to our cloud so they are available across your Apple devices.

- This content is **end-to-end encrypted** on your device using AES-256-GCM before it is uploaded. The encryption key is stored in your iCloud Keychain and never leaves your control. **Our servers store only ciphertext and cannot read your content.**
- Cloud Sync is optional. Disabling it **immediately deletes** all of your synced data from the cloud; your local data is unaffected.
- Used only to provide the sync feature (App Functionality). It is linked to your account identifier and is **not** used for tracking.

### 3. Identifiers
We use a user/account identifier (including the identifier provided by Sign in with Apple, if you choose to sign in) to operate your account, associate your subscription entitlement, and sync your encrypted data. Used for App Functionality only; not used for tracking.

Signing in is **optional** — the app is fully usable without an account. Account sign-in is offered only through Sign in with Apple. If you use Apple's private email relay, we never receive your real email address.

### 4. Purchases
ConchTalk Pro subscriptions are processed by Apple. We use a third-party service, **RevenueCat**, to manage subscription status and validate purchases. RevenueCat records purchase/transaction information and an app user identifier. Payment is handled entirely by Apple — we never receive or store your card or payment details. Used for App Functionality only; not used for tracking.

### 5. AI processing of your requests
When you ask ConchTalk to perform a task, your prompt and relevant context are sent to an AI model to plan and execute it:

- If you use the built-in managed AI service, your prompt is processed by that service to generate responses.
- If you configure your own API endpoint and key, your prompt is sent directly to the provider you chose, under that provider's terms.

We do not use your prompts to build advertising profiles or for tracking.

## What We Do NOT Do

- We do not use your data for third-party advertising, our own advertising, or marketing tracking.
- We do not share your data with data brokers.
- We do not sell your personal data.
- We do not access the contents of the remote servers you connect to, beyond executing the commands you (or the AI on your instruction) request.

## Data Retention and Deletion

- Local data remains on your device until you delete it or uninstall the app.
- Cloud-synced data is deleted from the cloud when you disable Cloud Sync or regenerate your encryption key. Deleted records follow a soft-delete with a limited retention window before permanent removal.
- You can request deletion of account-related data by contacting us at the address below.

## Security

User content synced to the cloud is end-to-end encrypted (AES-256-GCM, per-entity-type key derivation via HKDF). The master key is stored in the iCloud Keychain. SSH keys and passwords on your device are stored in the iOS Keychain.

## Children

ConchTalk is not directed to children and is intended for general audiences.

## Changes

We may update this policy from time to time. Material changes will be reflected by updating the date at the top of this document.

## Contact

Questions about this policy or your data: **zhang-xiaotian@earth-eyes.co.jp**

Source repository: https://github.com/snana7mi/conchtalk

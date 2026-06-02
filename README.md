# HelloID-Conn-Prov-Target-Ans

<!--
** for extra information about alert syntax please refer to [Alerts](https://docs.github.com/en/get-started/writing-on-github/getting-started-with-writing-and-formatting-on-github/basic-writing-and-formatting-syntax#alerts)
-->

> [!IMPORTANT]
> This repository contains the connector and configuration code only. The implementer is responsible to acquire the connection details such as username, password, certificate, etc. You might even need to sign a contract or agreement with the supplier before implementing this connector. Please contact the client's application manager to coordinate the connector requirements.

<p align="center">
  <img src="">
</p>

## Table of contents

- [HelloID-Conn-Prov-Target-Ans](#helloid-conn-prov-target-ans)
  - [Table of contents](#table-of-contents)
  - [Introduction](#introduction)
  - [Supported features](#supported-features)
  - [Getting started](#getting-started)
    - [HelloID Icon URL](#helloid-icon-url)
    - [Requirements](#requirements)
    - [Connection settings](#connection-settings)
    - [Correlation configuration](#correlation-configuration)
    - [Field mapping](#field-mapping)
    - [Account Reference](#account-reference)
  - [Remarks](#remarks)
  - [Development resources](#development-resources)
    - [API endpoints](#api-endpoints)
    - [API documentation](#api-documentation)
  - [Getting help](#getting-help)
  - [HelloID docs](#helloid-docs)

## Introduction

_HelloID-Conn-Prov-Target-Ans_ is a _target_ connector. _Ans_ provides a set of REST APIs that allow you to programmatically interact with its data.

## Supported features

The following features are available:

| Feature                                   | Supported | Actions                                 | Remarks           |
| ----------------------------------------- | --------- | --------------------------------------- | ----------------- |
| **Account Lifecycle**                     | ✅         | Create, Update, Enable, Disable, Delete | Delete does not remove the account from the system, it only disables it, and sets the alumni status op true                 |
| **Permissions**                           | ✅         | Retrieve, Grant, Revoke                | Static :  membership of class  |
| **Resources**                             | ✅         | Creates classes                        |                   |
| **Entitlement Import: Accounts**          | ✅         |                                        |                   |
| **Entitlement Import: Permissions**       | ✅        | reports the membership of classes      |                   |
| **Governance Reconciliation Resolutions** | ✅        |                                         |                   |



## Getting started

### HelloID Icon URL
URL of the icon used for the HelloID Provisioning target system.
```
https://raw.githubusercontent.com/Tools4everBV/HelloID-Conn-Prov-Target-Ans/refs/heads/main/Icon.png
```

### Requirements

The Concurrent actions setting must be set to 1


### Connection settings

The following settings are required to connect to the API.

| Setting  | Description                        | Mandatory |
| -------- | ---------------------------------- | --------- |
| SchoolId | The id of the school               | Yes       |
| studentNumberLength | The length of the student_number property, used for padding with zeros | Yes |
| Token     | The access token to connect to the API | Yes       |
| BaseUrl  | The URL to the API                 | Yes       | https://edu.ans.app

The Concurrent actions setting must be set to 1, because the connector needs to retrieve the existing class memberships when updating the class membership, and this can cause concurrency issues when multiple updates are happening at the same time.

### Correlation configuration

The correlation configuration is used to specify which properties will be used to match an existing account within _Ans_ to a person in _HelloID_.

| Setting                   | Value                             |
| ------------------------- | --------------------------------- |
| Enable correlation        | `True`                            |
| Person correlation field  | `PersonContext.Person.ExternalId` |
| Account correlation field | `student_number`                  |

> [!TIP]
> _For more information on correlation, please refer to our correlation [documentation](https://docs.helloid.com/en/provisioning/target-systems/powershell-v2-target-systems/correlation.html) pages_.

### Field mapping
 
The field mapping can be imported by using the _fieldMapping.json_ file.  Currently this contains mainly name and email address information

### Account Reference

The account reference is populated with the  `id` property from the _Ans_ account.

## Remarks

- When creating an account, the API itself automatically padds the student_number with zeros at the beginning to ensure a fixed length. This causes an issue for correlation because the search API does not pad the student_number provided with zeros. To solve this issue, the connector pads the student_number with zeros before searching for an existing account. The length of the student_number can be configured in the configuration file.
 
- The API enforces a rate limit determined by your organisation's pricing plan. If the rate limit is exceeded, the API responds with a HTTP 429 Too Many Requests response code.
  This connector will pause the provisioning job until the rate limit is reset, which is determinded by the 'rateLimit-Reset' header in the API response. 

- As an additional security measure, API users are limited to five updates per minute per record. This is not expected to cause issues, as updates to the same account are not expected to be frequent, especially with the concurrent actions setting set to 1.

- The delete operation does not remove the account from the system, it only disables it, and sets the alumni status to true . When the user is reboarded the existing account is re-enabled and the alumni status is set to false. 

## Development resources

### API endpoints

The following endpoints are used by the connector

| Endpoint | HTTP Method      | Description                                  |
| -------- | ---------------- | -------------------------------------------- |
| /api/v2/schools/{schoolId}/users | GET | Retrieve user information for import |
  /api/v2/schools/{schoolId}/users | POST | Create a new user |
| /api/v2/schools/{schoolId}/classes | GET | Retrieve the classes of a school | used for permissions and permission membership import
| /api/v2/schools/{schoolId}/classes | POST | Create a new class | used for resource creation|
| /api/v2/search/users   | GET |  correlate users |
| /api/v2/users/{userId} | PATCH | Update, Enable, Disable , Delete* an existing user |  Delete does not remove the account from the system, it only disables it, and sets the alumni status op true
| /api/v2/classes/{classId} | GET | Retrieve class membership information | used for permission membership import, adn for granting and revoking permissions to retrieve the existing class memberships before updating them  
| /api/v2/classes/{classId} | PATCH | Update class membership information | used for granting and revoking permissions


### API documentation

https://edu.ans.app/api/docs/index.html#/

## Getting help

> [!TIP]
> _For more information on how to configure a HelloID PowerShell connector, please refer to our [documentation](https://docs.helloid.com/en/provisioning/target-systems/powershell-v2-target-systems.html) pages_.

## HelloID docs

The official HelloID documentation can be found at: https://docs.helloid.com/

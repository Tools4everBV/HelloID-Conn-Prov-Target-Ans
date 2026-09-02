# Change Log

All notable changes to this project will be documented in this file. The format is based on [Keep a Changelog](https://keepachangelog.com), and this project adheres to [Semantic Versioning](https://semver.org).


## [1.2.0] - 02-09-2026

### Added
- Sub-permission script for ANS classes: dynamically grants and revokes class memberships based on contract conditions (`InConditions`).
- Required `AnsStudentNumber` Custom person field on the HelloID source. Padding of the student number is now performed source-side (JavaScript reference implementation in the README).
- Standardised `Action` field on every audit log entry, and consistent inclusion of the AccountReference, correlation field/value, updated properties, and resource identifiers in audit messages.

### Changed
- Audit messages harmonised across all scripts (verb tense, phrasing, and formatting).
- Update-account audits now report which properties were updated and on which account.
- Create-account error audits now include the correlation field and value used for the search.
- Resource create/update audits now include the resource `external_id` and school year.
- README rewritten: spelling and grammar corrected, tables reformatted, and documentation added for the `AnsStudentNumber` Custom person field.

### Fixed
- Delete/Disable/Enable/Update now correctly enter the "account no longer exists" (NotFound) flow when the ANS user has been removed. Previously these scripts silently failed with a parameter-binding error.
- HTTP 429 retry counter now increments only on actual retries; previously it counted every loop iteration, effectively allowing fewer retries than configured.
- Sub-permission processing now iterates over every in-condition contract (was only the primary contract), so people with multiple simultaneously in-condition contracts receive the correct set of class memberships.
- Removed a duplicate `Content-Type` header that could cause request failures on Windows PowerShell 5.1.

### Removed
- Configuration keys `UseStudentNumberPadding` and `studentNumberLength`. Student-number padding is now performed by the HelloID source via the `AnsStudentNumber` Custom person field.
- Invalid audit `Action` value `ManageSubPermissions`; sub-permission runs now use `GrantPermission` or `RevokePermission` based on the current operation.
- `"No permissions defined"` placeholder sub-permission. Accounts that produce zero sub-permissions now yield an empty set.

## [1.1.0] - 15-06-2026

### Changed
- Fixed issue with parsing total pages header.
- Updated documentation for better clarity.
- Fixed issue with storing Accountreference on creation of a new target account.
- Fixed issue with correlation on account import. 

### Added
- Added support for updating existing resources in resource provisioning.

## [1.0.0] - 23-04-2026

This is the first official release of _HelloID-Conn-Prov-Target-Ans_. This release is based on template version _v4.1.1_.

### Added

### Changed

### Deprecated

### Removed
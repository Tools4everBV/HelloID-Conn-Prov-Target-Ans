# Change Log

All notable changes to this project will be documented in this file. The format is based on [Keep a Changelog](https://keepachangelog.com), and this project adheres to [Semantic Versioning](https://semver.org).

## [1.1.1] - 13-08-2026

### Changed

- Made the *enable*, *disable* and *delete* actions conditional.
- Removed the `ConvertTo-HelloIDAccount` function from the *enable*, *disable*, *delete*, *grant* and *revoke* actions.

### Fixed

- Improved error handling when retrieving accounts. When an account did not exist, a `NullReferenceException` was thrown by the `ConvertTo-HelloIDAccount` function.
- Changed the  

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

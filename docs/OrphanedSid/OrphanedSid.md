---
document type: module
Help Version: 1.0.0.0
HelpInfoUri: 
Locale: en-US
Module Guid: 7d3f2a9e-5b61-4c08-9e4a-2f8c1b6d0a37
Module Name: OrphanedSid
ms.date: 11/08/2026
PlatyPS schema version: 2024-05-01
title: OrphanedSid Module
---

# OrphanedSid Module

## Description

Finds orphaned SIDs in Active Directory ACLs, removes them with a backup of every ACL it touches, and restores an ACL from that backup

## OrphanedSid

### [Find-OrphanedSid](Find-OrphanedSid.md)

Finds access control entries in Active Directory that grant rights to principals that no longer exist.

### [Remove-OrphanedSid](Remove-OrphanedSid.md)

Removes orphaned access control entries from Active Directory objects after backing up each ACL.

### [Restore-OrphanedSidBackup](Restore-OrphanedSidBackup.md)

Restores Active Directory ACLs from a backup folder written by Remove-OrphanedSid.


import Foundation

// The provisioning bundle never runs. Building it asks Xcode to create or
// renew the Mac Team provisioning profile that grants keychain-access-groups
// for com.universalvault.app. See scripts/provision.sh.
exit(0)

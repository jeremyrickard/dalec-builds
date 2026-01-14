#!/bin/sh

set -eu

# Find iptables binary location
if ! command -v iptables &> /dev/null; then
    echo "ERROR: iptables is not present in either /usr/sbin or /sbin" 1>&2
    exit 1
fi

# Determine how the system selects between iptables-legacy and iptables-nft
if [ -f /etc/azurelinux-release ]; then
    altstyle="azlinux3"
elif [ -x /usr/sbin/update-alternatives ]; then
    # Debian style alternatives
    altstyle="debian"
else
    echo "ERROR: only support azlinux3 and debian alternatives style" 1>&2
    exit 1
fi

echo "Detected alternatives style: ${altstyle}"

# In kubernetes 1.17 and later, kubelet will have created at least
# one chain in the "mangle" table (either "KUBE-IPTABLES-HINT" or
# "KUBE-KUBELET-CANARY"), so check that first, against
# iptables-nft, because we can check that more efficiently and
# it's more common these days.
nft_kubelet_rules=$( (iptables-nft-save -t mangle || true; ip6tables-nft-save -t mangle || true) 2>/dev/null | grep -E '^:(KUBE-IPTABLES-HINT|KUBE-KUBELET-CANARY)' | wc -l)
if [ "${nft_kubelet_rules}" -ne 0 ]; then
    mode=nft
else
    # Check for kubernetes 1.17-or-later with iptables-legacy. We
    # can't pass "-t mangle" to iptables-legacy-save because it would
    # cause the kernel to create that table if it didn't already
    # exist, which we don't want. So we have to grab all the rules
    legacy_kubelet_rules=$( (iptables-legacy-save || true; ip6tables-legacy-save || true) 2>/dev/null | grep -E '^:(KUBE-IPTABLES-HINT|KUBE-KUBELET-CANARY)' | wc -l)
    if [ "${legacy_kubelet_rules}" -ne 0 ]; then
        mode=legacy
    else
        # With older kubernetes releases there may not be any _specific_
        # rules we can look for, but we assume that some non-containerized process
        # (possibly kubelet) will have created _some_ iptables rules.
        num_legacy_lines=$( (iptables-legacy-save || true; ip6tables-legacy-save || true) 2>/dev/null | grep '^-' | wc -l)
        num_nft_lines=$( (iptables-nft-save || true; ip6tables-nft-save || true) 2>/dev/null | grep '^-' | wc -l)
        if [ "${num_legacy_lines}" -gt "${num_nft_lines}" ]; then
            mode=legacy
        else
            mode=nft
        fi
    fi
fi

# Write out the appropriate alternatives-selection commands
case "${altstyle}" in
    azlinux3)
        # update links 
        alternatives --set iptables "/usr/sbin/iptables-${mode}" > /dev/null || failed=1
        alternatives --set ip6tables "/usr/sbin/ip6tables-${mode}" > /dev/null || failed=1
    ;;
    debian)
        # Update links to point to the selected binaries
        update-alternatives --set iptables "/usr/sbin/iptables-${mode}" > /dev/null || failed=1
        update-alternatives --set ip6tables "/usr/sbin/ip6tables-${mode}" > /dev/null || failed=1
    ;;
esac


if [ "${failed:-0}" = 1 ]; then
    echo "ERROR: Unable to redirect iptables binaries. (Are you running in an unprivileged pod?)" 1>&2
    exit 1
fi

# Use ip link show ip6_tables to force the mod to be loaded if not. 
# Inspired by https://twitter.com/lucabruno/status/902934379835662336
ip link show ip6_tables &>/dev/null || true

# Start kube-proxy that is installed by our package
exec /usr/bin/kube-proxy "$@"



# Free Generation Tree

Adds a Free Generation Tree tab beside Generation Tree, using the existing network layout, flags, avatars, branch navigation and level controls.

The read-only projection starts with the existing authorized sponsor traversal. It retains free accounts and only the ancestors needed to connect them to the selected root. Paid ancestors are labelled Sponsor connection and excluded from the free count. Original parent relationships and generation depths remain intact. Package activation removes a free entry automatically on the next network load; it can remain as a labelled connector if free descendants still require it.

No account, sponsor, placement, activation, reward or wallet writes are introduced. Existing limits (10 sponsor levels for members, bounded snapshots and existing admin access) remain in force. The pure private projection has no client execute grants.

Validation:
- Isolated PostgreSQL tests cover mixed paid/free branches, connector pruning, accurate counts, original depths, authorized branch selection, cross-network/anonymous rejection, activation transitions, empty trees and cyclic snapshots.
- Interface suite: 134 checks passed, including new-tab RPC selection and branch navigation in the free view.
- Network UI tests cover labels, counts, free-account details without binary metrics, flags, avatars and empty states; existing tree layouts remain covered.
- Build, syntax checks and PWA tests passed. Browser previews checked at mobile and desktop widths; 320px tab row has no horizontal overflow.
- Production read-only query confirms the expected direct free account under its sponsor. Before/after fingerprints match for other functions, sponsor links, placements, point ledger, bonus transactions and activations.
- Security advisor findings unchanged.

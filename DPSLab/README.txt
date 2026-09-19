DPSLab v0.6.0-alpha

NEW IN v0.6.0
- Gaia-inspired dark teal / gold UI theme for the main window and compact HUD.
- Damage tab now shows Melee, Ranged, and WS hits / attempts / accuracy.
- Group adds per-player physical accuracy (melee + ranged).
- Skillchain damage is detected from 0x028 additional-effect messages and shown as its own damage bucket.
- Solo/self-created WS skillchains are credited to the closing player's Total / DPS.
- Shared skillchains are kept separate in Group rather than credited entirely to the closer.
- Uncertain skillchain ownership is preserved as Unresolved SC rather than guessed.
- Group now contains a Live-vs-Group self diagnostic showing damage, DPS, active-time, and capture-window deltas.
- Live and Group use the same outgoing-combat active-time model for DPS, fixing the prior mismatch caused by support/incoming events extending only Live's denominator.
===================

DPSLab is an Ashita v4 combat parser / benchmarking addon focused on controlled
solo gear testing while retaining a lightweight party/alliance group parser.

INSTALL
-------
Place the `dpslab` folder in:

  ashita/addons/dpslab/

Then load it with:

  /addon load dpslab

LIVE + GROUP CAPTURE
--------------------
Both parsers start CAPTURING when the addon loads.

Live tab:
  Start Live   - resume solo capture without clearing existing values
  Stop Live    - freeze solo values
  Reset Live   - clear only solo values

Group tab:
  Start Group  - resume group capture without clearing existing values
  Stop Group   - freeze group scores
  Reset Group  - clear only group scores

Commands:
  /dpslab live start|stop|reset
  /dpslab group start|stop|reset
  /dpslab reset                  (resets both)

DAMAGE + ACCURACY
-----------------
Damage now keeps separate buckets for:
  Melee
  Ranged
  Weaponskills
  Magic
  Abilities
  Additional / proc
  Skillchain - Solo
  Skillchain - Shared
  Skillchain - Unresolved

Melee, Ranged, and Weaponskills also show packet-observed hits, attempts, and
hit rate. Group's Acc column intentionally uses melee + ranged only so it matches
the Live-tab Accuracy metric. Magic/ability rows do not claim an accuracy value
because resist / land semantics are not equivalent to physical hit rate.

SKILLCHAIN ATTRIBUTION
----------------------
Skillchain damage is read from the additional-effect portion of the incoming
0x028 action packet. For weapon-skill chains, DPSLab tracks the immediately
preceding landed WS on the same target:

  same actor -> Solo SC -> credited to that player's Total / DPS
  different actor -> Shared SC -> shown separately in Group
  opener not confidently known -> Unresolved SC -> shown, not player-credited

This is intentionally conservative. Magic / pet-generated chains can still be
detected as skillchain damage, but their ownership may remain Unresolved until
a stronger opener-tracking path is added.

LIVE VS GROUP DIAGNOSTIC
------------------------
The Group tab includes a local-player comparison showing:
  Live damage vs Group self damage
  Live DPS vs Group self DPS
  Live active seconds vs Group self active seconds
  Live capture elapsed vs Group capture elapsed

This is meant to make parser discrepancies auditable. Live and Group now both
use outgoing offensive activity for their DPS denominator; incoming damage and
support-only actions no longer lengthen only the Live DPS clock.

TEST LAB - LAC COMMAND DISCOVERY
--------------------------------
Test Lab no longer depends on equipment-set names. DPSLab scans the currently
loaded LuAshitacast profile's `profile.HandleCommand(args)` and discovers
A/B-testable `/lac fwd` command families.

Example profile logic:

  local shotModes = { 'Normal', 'Accuracy', 'Attack' };

  profile.HandleCommand = function(args)
      if args[1] == 'shot' then
          local requested = setModeFromArg(shotModes, args[2]);
          ...
      end
  end

DPSLab discovers:

  Group: Shot
  Options: Normal / Accuracy / Attack

Selecting:

  Test A = Normal
  Test B = Accuracy

causes the captures to issue:

  /lac fwd shot Normal
  /lac fwd shot Accuracy

The profile remains responsible for what those commands actually do. DPSLab
never assumes that a command maps to a particular named equipment set.

The scanner supports:
  - literal args[1] / args[2] comparisons
  - args[n]:lower() comparisons
  - string.lower(args[n]) comparisons
  - Gaia-style `setModeFromArg(modeTable, args[2])` where modeTable is a literal
    local string list

One-shot commands with no discoverable second-level values (for example
`/lac fwd status`) are intentionally omitted from the A/B dropdowns.

Use `Query Active LAC Profile` or `Rescan Current Path` after changing/reloading
a profile. DPSLab also watches normal `/lac load` and `/lac reload` commands.

MANUAL / CUSTOM TEST MODE
-------------------------
Enable `Manual / custom test mode` if a profile does not expose statically
parseable command families, or if you want completely generic labels.

Example:
  Test A Name: Blah Test Set 1
  Test B Name: Blah Test Set 2

Optional LAC commands can also be entered. A command without a leading `/` is
treated as arguments to `/lac fwd`.

Manual runs receive the same capture, Compare, equipment snapshot, and History
behavior as automatically discovered LAC runs.

CAPTURE SCOPE + EQUIPMENT OBSERVATION
-------------------------------------
Capture Scope controls which self action packets are used to sample actual worn
equipment during a benchmark:

  Auto       - Shot/Ranged -> ranged; TP/Melee -> melee; WS -> weaponskill
  Melee / TP
  Ranged
  WS
  All

DPSLab snapshots actual equipment during matching self action packets and saves
the dominant observed equipment state with the finished run. This is purposely
separate from profile set names.

Important: DPSLab can confirm the command it issued and the actual gear it
observed during matching actions. It cannot generically inspect arbitrary local
Lua variables inside a profile, so it does not claim that a private profile
variable changed unless the resulting equipment/action state provides evidence.

TARGET LOCK
-----------
`Lock benchmark to first enemy target` optionally binds a Test Lab run to the
first enemy the local player acts on. Later self actions against a different
target are excluded from the benchmark and the run receives a warning flag.

STOP RULES
----------
A benchmark can stop manually or automatically after:
  - N seconds
  - N melee rounds
  - N weaponskills

A completed A or B run is frozen and Live capture stops so its result cannot
continue changing.

COMPARE
-------
Compare is SOLO / LOCAL PLAYER ONLY. Group parser data is never included.

After completing A and B, Compare shows:
  DPS
  Total damage
  Self / melee / ranged TP per second
  Accuracy
  Hits per melee round
  WS count / average WS / average pre-WS TP
  Damage buckets
  Active time
  B-A deltas
  Observed equipment differences between dominant scoped action snapshots

HISTORY
-------
Every stopped Test Lab run is written locally to:

  ashita/addons/dpslab/History/benchmarks.tsv

The History tab intentionally keeps each run to one clean line:

  YYYY-MM-DD HH:MM | JOB/SUB | Test Name | MM:SS

Select a row for a compact detail view. A selected historical run can be loaded
as Compare A or Compare B.

PARSERLOGS
----------
Optional event-feed CSV logging remains available in Settings or with:

  /dpslab log on
  /dpslab log off

Files are written to:

  ashita/addons/dpslab/ParserLogs/

NOTES / CURRENT LIMITATIONS
---------------------------
- Group TP/s is observational because other clients' complete TP-source context
  is not available locally.
- Static LAC command discovery cannot infer every possible dynamically generated
  Lua command value. Manual mode is the fallback for those profiles.
- Equipment sampling is packet-timed. It records the actual equipment observed
  during matching self actions rather than evaluating arbitrary private profile
  state.
- Repeated-trial statistics (A1/B1/A2/B2 aggregation) and warm-up exclusion are
  intentionally left for a later revision after this workflow is validated.

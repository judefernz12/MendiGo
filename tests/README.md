# Automated checks

These run the real `Server.gd` and the real `GameRoom3D.tscn` headlessly, with
no network and no window. They are excluded from every export preset.

Run from the project root (use the same Godot version as the project):

```powershell
& "C:\path\to\Godot_v4.7.1-stable_win64_console.exe" --headless --path . -s tests/rules_test.gd
& "C:\path\to\Godot_v4.7.1-stable_win64_console.exe" --headless --path . -s tests/render_test.gd
```

`rules_test.gd` prints `ALL_RULES_OK` and exits 0 when every rule in
`GameRules.txt` that can be checked automatically holds. It plays a complete
4-player game against bots and verifies:

- deck size and 2s removal per player count (4/6/8)
- deal patterns 5+4+4 / 4+4 / 3+3, dealt in play direction from the dealer
- the deal pauses for the trump-mode choice
- trump holder is the player after the dealer
- hidden trump is redacted from every snapshot, including its holder's
- opponent hands are redacted
- follow-suit and out-of-turn plays are rejected
- every trick winner (highest trump, else highest lead suit)
- 13 tricks, 4 tens, court = 5 points, normal = 2, tie broken by tricks
- dealer rotation and score carry-over into the next game

`render_test.gd` prints `ALL_RENDER_OK` and exits 0 when the table renders
correctly. It feeds real server snapshots into the real game scene and checks:

- the opening deal draws the right cards and reveals only the local hand
- opponent cards are never face up while in hand
- re-sending a snapshot does not re-create (re-deal) any card
- cards that stay in hand keep the same node while playing
- the hidden trump moves to its slot face down and only that card leaves hand
- completed tricks end up in a captured pile matching the server's counts
- captured 10s are displayed on the piles

Both tests take 1-3 minutes because they wait out the server's real bot and
trick-resolve delays.

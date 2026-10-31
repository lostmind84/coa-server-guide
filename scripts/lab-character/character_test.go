// Package labcharacter is driven as a Go test (not a CLI) because the Ghost e2e harness
// (github.com/azerothcore/AzerothGhost/e2e/e2eharness) is built around *testing.T: every
// setup helper (LoginBot, SetLevel, Learn, EquipEntry, SetSpecialization...) takes one and
// fails the run with t.Fatalf. coa-client-lab character drives this with `go test -run`,
// passing the request as JSON in COA_LAB_CHARACTER_SPEC and reading the JSON result back
// from the file named by COA_LAB_CHARACTER_OUT.
package labcharacter

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/azerothcore/AzerothGhost/e2e/e2eharness"
	_ "github.com/go-sql-driver/mysql"
)

// ClassMin and ClassMax bound the CoA (Ascension) class ids; see
// src/server/shared/SharedDefines.h (CLASS_BARBARIAN=12 .. CLASS_SPIRIT_MAGE=32,
// IsAscensionClass). Every id in the range is a real CoA class: no gaps to special-case.
const (
	ClassMin uint8 = 12
	ClassMax uint8 = 32
)

// MaxAccountLen mirrors MAX_ACCOUNT_STR (src/server/game/Accounts/AccountMgr.h:34): the length
// AccountMgr::CreateAccount/ChangeUsername refuse past. LabAccountPrefix must match the server
// repo's CoA.ProbeRelay.AccountPrefix default ("COALAB", src/server/coa/CoAProbeRelay.cpp:28-63 in
// the client-lab worktree): only an account starting with it can be probed through the relay
// (docs/design/client-lab-level3.md "Only accounts whose name starts with COALAB can be probed").
// A derived account marks itself as this tool's own (one character each), distinct from a
// user-chosen --account that may deliberately be shared across characters (bank, account-bound
// items, char-select screen).
const (
	MaxAccountLen    = 17
	LabAccountPrefix = "COALAB"
)

// DeriveAccount returns the dedicated lab account name for one character: LabAccountPrefix plus
// the upper-cased character name, truncated to MaxAccountLen. Unlike Ghost's own
// ScenarioOpts.Prefix + a random 10-char suffix (which exists so concurrent bots never collide on
// a name neither side chose), this name is deterministic and chosen by the caller, so a long
// character name can truncate into another one's derived account; TestLabCharacterApply's
// dedicated-account refusal (a derived account may hold only one character) catches that collision
// instead of silently reusing the wrong account.
func DeriveAccount(character string) (string, error) {
	if character == "" {
		return "", fmt.Errorf("character name is empty")
	}
	account := LabAccountPrefix + strings.ToUpper(character)
	if len(account) > MaxAccountLen {
		account = account[:MaxAccountLen]
	}
	return account, nil
}

// Spec is one coa-client-lab character request.
type Spec struct {
	Account   string   `json:"account"`
	Character string   `json:"character"`
	Race      uint8    `json:"race"`
	Class     uint8    `json:"class"`
	Level     int      `json:"level"`
	Spec      uint32   `json:"spec"`
	GM        int      `json:"gm"`
	Learn     []uint32 `json:"learn"`
	Items     []uint32 `json:"items"`
	BagItems  []uint32 `json:"bag_items"`
	// Password overrides e2eharness.DefaultPassword when set: coa-client-lab's --account path
	// (today's behavior) leaves this empty; the dedicated-account path sets it from a generated,
	// persisted password file so `login CHARACTER` can read the same password back.
	Password string `json:"password,omitempty"`
	// Dedicated marks the account as one meant to hold exactly this one character: set when
	// coa-client-lab derived the account itself (--account was not given). A second, differently
	// named character already on the account is then a refusal, not a warning.
	Dedicated bool `json:"dedicated,omitempty"`
}

// Result is written to COA_LAB_CHARACTER_OUT on success.
type Result struct {
	Account   string   `json:"account"`
	Character string   `json:"character"`
	GUID      uint64   `json:"guid"`
	Race      uint8    `json:"race"`
	Class     uint8    `json:"class"`
	Level     int      `json:"level"`
	Spec      uint32   `json:"spec,omitempty"`
	GM        int      `json:"gm"`
	Learned   []uint32 `json:"learned,omitempty"`
	Equipped  []uint32 `json:"equipped,omitempty"`
	Created   bool     `json:"created"`
	// AccountCharacters lists every active character on the account after this call, in glue
	// display order. coa-client-lab warns when this has 2+ entries on an explicit (non-dedicated)
	// --account, since `login CHARACTER` alone cannot resolve which account to use and
	// character-select navigation by name is disabled (see select_character).
	AccountCharacters []string `json:"account_characters,omitempty"`
}

// ValidateClass refuses any class outside the CoA range (12-32). Kept standalone (no *testing.T,
// no DB) so it is covered by a plain offline unit test.
func ValidateClass(class uint8) error {
	if class < ClassMin || class > ClassMax {
		return fmt.Errorf("class %d is not a CoA class (%d-%d)", class, ClassMin, ClassMax)
	}
	return nil
}

func loadSpec() (Spec, error) {
	var s Spec
	raw := os.Getenv("COA_LAB_CHARACTER_SPEC")
	if raw == "" {
		return s, fmt.Errorf("COA_LAB_CHARACTER_SPEC is empty")
	}
	if err := json.Unmarshal([]byte(raw), &s); err != nil {
		return s, fmt.Errorf("COA_LAB_CHARACTER_SPEC: %w", err)
	}
	if s.Account == "" || s.Character == "" {
		return s, fmt.Errorf("account and character are required")
	}
	return s, ValidateClass(s.Class)
}

func writeResult(t *testing.T, r Result) {
	t.Helper()
	out := os.Getenv("COA_LAB_CHARACTER_OUT")
	if out == "" {
		t.Fatalf("COA_LAB_CHARACTER_OUT is empty")
	}
	data, err := json.MarshalIndent(r, "", "  ")
	if err != nil {
		t.Fatalf("marshal result: %v", err)
	}
	if err := os.WriteFile(out, append(data, '\n'), 0o600); err != nil {
		t.Fatalf("write result: %v", err)
	}
}

// existingCharacterClass looks up guid/class for account+name, mirroring the account-scoped
// lookup CHAR_SEL_ENUM uses (CharacterDatabase.cpp): WHERE c.account = ? AND c.deleteInfos_Name IS NULL.
func existingCharacterClass(authDB, charDB *sql.DB, account, character string) (class uint8, guid uint64, exists bool, err error) {
	var accountID int
	if err = authDB.QueryRow(`SELECT id FROM account WHERE username=?`, strings.ToUpper(account)).Scan(&accountID); err != nil {
		return 0, 0, false, fmt.Errorf("account %s: %w", account, err)
	}
	err = charDB.QueryRow(
		`SELECT guid, class FROM characters WHERE account=? AND name=? AND deleteInfos_Name IS NULL`,
		accountID, character,
	).Scan(&guid, &class)
	if err == sql.ErrNoRows {
		return 0, 0, false, nil
	}
	if err != nil {
		return 0, 0, false, err
	}
	return class, guid, true, nil
}

// ascensionActiveSpecSetting mirrors ASCENSION_ACTIVE_SPEC_SETTING (src/server/coa/AscensionCompat.cpp
// in the server repo): the character_settings "source" OnPlayerLogin reads to decide the active CoA
// specialization (player->GetPlayerSetting(ASCENSION_ACTIVE_SPEC_SETTING, 0).value) and then grants
// through SynchronizeAutomaticTalents/SynchronizeProgression.
const ascensionActiveSpecSetting = "core.ascension_active_spec"

// setActiveSpecialization stages a CoA specialization the way the current server actually honors it.
// Ghost's ScenarioBot.SetSpecialization whispers `.localspec N`, which server commit 2d13ffd73a (#5507,
// "talk to the client through native Extensions.dll packets only") removed along with every other
// ASC_LOCAL_* chat command; the whisper is now silently ignored (no handler), so the character's
// character_settings row never changes and the call is a no-op. #5507 replaced it with CMSG 0x0727
// (known-entries upload) from the client's ChrSpecs identity/signature entries -- not reachable from a
// chat whisper -- but OnPlayerLogin (src/server/coa/AscensionCompat.cpp) still reads
// core.ascension_active_spec from character_settings on every login, independent of that packet, and
// uses it to populate the in-memory active-specialization map and synchronize the automatic (identity)
// entries for that spec. Writing this row directly is therefore a path the server still honors today,
// without depending on a chat command or constructing a native upload the harness has no DBC catalog to
// validate. It only stages the switch: the actual spellbook sync happens in OnPlayerLogin, i.e. on the
// character's *next* login (the lab client's own `coa-client-lab login`, not this helper's own
// session) -- matching PlayerSettingsStore::UpdateSetting's REPLACE-based design, which is meant to work
// for an offline character.
//
// The wire format (PlayerSettingsStore::SerializeSettingsData, src/server/game/Entities/Player/
// PlayerSettings.cpp) is one decimal value followed by a trailing space, and CHAR_REP_CHAR_SETTINGS
// (src/server/database/Database/Implementation/CharacterDatabase.cpp) is a plain
// `REPLACE INTO character_settings (guid, source, data) VALUES (?, ?, ?)`, reproduced here verbatim.
func setActiveSpecialization(charDB *sql.DB, guid uint64, spec uint32) error {
	data := fmt.Sprintf("%d ", spec)
	if _, err := charDB.Exec(
		`REPLACE INTO character_settings (guid, source, data) VALUES (?, ?, ?)`,
		guid, ascensionActiveSpecSetting, data,
	); err != nil {
		return fmt.Errorf("write character_settings %s for guid %d: %w", ascensionActiveSpecSetting, guid, err)
	}
	readBack, err := readActiveSpecialization(charDB, guid)
	if err != nil {
		return err
	}
	if readBack != data {
		return fmt.Errorf("character_settings %s for guid %d did not persist: wrote %q, read back %q",
			ascensionActiveSpecSetting, guid, data, readBack)
	}
	return nil
}

// readActiveSpecialization returns the raw character_settings data for guid's
// core.ascension_active_spec row ("" if there is none yet), with no write of its own: the one way to
// tell whether a previous setActiveSpecialization write is still there, or something (the server's own
// pending logout save) has since reverted it.
func readActiveSpecialization(charDB *sql.DB, guid uint64) (string, error) {
	var data string
	err := charDB.QueryRow(
		`SELECT data FROM character_settings WHERE guid = ? AND source = ?`,
		guid, ascensionActiveSpecSetting,
	).Scan(&data)
	if err == sql.ErrNoRows {
		return "", nil
	}
	if err != nil {
		return "", fmt.Errorf("read character_settings %s for guid %d: %w", ascensionActiveSpecSetting, guid, err)
	}
	return data, nil
}

// TestLabCharacterApply creates or updates the lab test character described by
// COA_LAB_CHARACTER_SPEC. Run with: go test -run '^TestLabCharacterApply$' -v
func TestLabCharacterApply(t *testing.T) {
	spec, err := loadSpec()
	if err != nil {
		t.Fatalf("%v", err)
	}
	gm := spec.GM
	if gm == 0 {
		gm = 3
	}

	authDB, err := e2eharness.OpenAuthDB()
	if err != nil {
		t.Fatalf("auth db: %v", err)
	}
	defer authDB.Close()
	charDB, err := e2eharness.OpenCharDB()
	if err != nil {
		t.Fatalf("char db: %v", err)
	}
	defer charDB.Close()

	password := spec.Password
	if password == "" {
		password = e2eharness.DefaultPassword
	}
	if err := e2eharness.EnsureAccount(authDB, spec.Account, password); err != nil {
		t.Fatalf("ensure account: %v", err)
	}
	if err := e2eharness.SetGM(authDB, spec.Account, gm); err != nil {
		t.Fatalf("set gm: %v", err)
	}

	if spec.Dedicated {
		// A dedicated account (derived by coa-client-lab, not given via --account) holds exactly
		// one character, so `login CHARACTER` alone never has to pick from a character list. A
		// different name already there means either a real second character or a name collision
		// from DeriveAccount's truncation; either way this is a refusal, not a silent reuse.
		conflict, err := dedicatedAccountConflict(authDB, charDB, spec.Account, spec.Character)
		if err != nil {
			t.Fatalf("dedicated account character listing: %v", err)
		}
		if conflict != "" {
			t.Fatalf("dedicated lab account %s already holds a different character %q; a dedicated"+
				" account holds exactly one character (pass --account to share an account across"+
				" characters, or pick a different character name)", spec.Account, conflict)
		}
	}

	existingClass, existingGUID, exists, err := existingCharacterClass(authDB, charDB, spec.Account, spec.Character)
	if err != nil {
		t.Fatalf("existing character lookup: %v", err)
	}
	if exists && existingClass != spec.Class {
		t.Fatalf("character %q already exists on %s as class %d (guid %d); refusing to change it to class %d"+
			" (delete it yourself first if that is really what you want)",
			spec.Character, spec.Account, existingClass, existingGUID, spec.Class)
	}

	sess, err := e2eharness.LoginBot(t, e2eharness.LoginOptions{
		User: spec.Account, Password: password,
		CharName: spec.Character, Race: spec.Race, Class: spec.Class,
	})
	if err != nil {
		t.Fatalf("login: %v", err)
	}
	defer sess.World.Close()

	bot := &e2eharness.ScenarioBot{
		Session: sess, AuthDB: authDB, CharDB: charDB,
		Ident: e2eharness.BotIdent{Account: spec.Account, CharName: sess.Name, Race: spec.Race, Class: spec.Class},
	}

	e2eharness.EnableGM(t, sess.World)
	if spec.Level > 0 {
		e2eharness.SetLevel(t, sess.World, spec.Level)
	}
	for _, spell := range spec.Learn {
		bot.Learn(t, spell)
	}
	for _, item := range spec.Items {
		bot.EquipEntry(t, item, 1)
		// EquipEntry (.additem + AutoEquipItem) is best-effort and does not fail on refusal (e.g. a
		// paper-doll slot the character's class cannot use: AllowableClass in Item.dbc). Check the
		// paper-doll ourselves so a class-restricted item is a clear, named refusal instead of a
		// silent no-op (controller finding: the last agent had to write /run bag-scan Lua to notice
		// item 9701803, AllowableClass=131072, did not equip on a non-class-18 character).
		if slot, ok := bot.EquippedSlot(item); !ok {
			t.Fatalf("item %d did not equip on class %d (slot=%d found=%v): likely refused by its"+
				" AllowableClass restriction in Item.dbc; it stays in the backpack instead", item, spec.Class, slot, ok)
		}
	}
	for _, item := range spec.BagItems {
		bot.AddItem(t, item, 1)
	}
	bot.Save(t)

	if spec.Spec != 0 {
		// A direct character_settings write only sticks once nothing server-side can save the
		// character's *old* in-memory settings back over it. A bare bot.Save(t) above is not enough:
		// the player object this session created still holds spec 0 in memory, and a defer'd
		// sess.World.Close() -- an abrupt disconnect, not a clean logout -- still triggers the
		// server's own on-disconnect save with that same stale value, clobbering this write right
		// after it lands (reproduced live, slot 2, 2026-10-27: the row read back "0 " immediately
		// after a plain mid-session UPDATE). Logging out properly first, and waiting for the
		// server's own SMSG_LOGOUT_COMPLETE, moves past every save this session can still trigger, so
		// the write made afterward is the last one before the character's next login.
		if err := sess.World.SendLogout(); err != nil {
			t.Fatalf("logout before setting specialization: %v", err)
		}
		if err := sess.World.WaitForLogout(30 * time.Second); err != nil {
			t.Fatalf("waiting for logout before setting specialization: %v", err)
		}
		if err := setActiveSpecialization(charDB, sess.GUID, spec.Spec); err != nil {
			t.Fatalf("set specialization: %v", err)
		}
		// setActiveSpecialization's own read-back (above) only proves the write landed at that
		// instant -- it does not prove nothing overwrites it a moment later. SaveToDB runs
		// synchronously inside WorldSession::LogoutPlayer, before SMSG_LOGOUT_COMPLETE is sent
		// (src/server/game/Server/WorldSession.cpp), but that call only *queues* the save onto
		// CharacterDatabase's async worker; WaitForLogout above only proves the client saw the
		// packet, not that the queued transaction has actually run yet. Reproduced live, slot 2,
		// 2026-10-27: the very write above stuck immediately for one character (guid 16) and lost
		// the race against that still-pending async save for the next two (17, 18) -- each read back
		// "0 " a few seconds later despite its own immediate read-back having just confirmed "36 ".
		// There is no notification for "the async save queue drained", so this settles for real by
		// re-reading (without rewriting) until the value holds across specSettleChecks consecutive
		// checks, re-writing and restarting the count on any check that still finds it reverted.
		const (
			specSettleWait     = 1 * time.Second
			specSettleChecks   = 3
			specSettleAttempts = 10
		)
		stable := 0
		for attempt := 0; attempt < specSettleAttempts && stable < specSettleChecks; attempt++ {
			time.Sleep(specSettleWait)
			data, err := readActiveSpecialization(charDB, sess.GUID)
			if err != nil {
				t.Fatalf("re-reading specialization while it settles: %v", err)
			}
			if data == fmt.Sprintf("%d ", spec.Spec) {
				stable++
				continue
			}
			stable = 0
			if err := setActiveSpecialization(charDB, sess.GUID, spec.Spec); err != nil {
				t.Fatalf("re-setting specialization after it reverted: %v", err)
			}
		}
		if stable < specSettleChecks {
			t.Fatalf("specialization did not settle on %d after %d attempt(s): something keeps reverting"+
				" character_settings %s for guid %d", spec.Spec, specSettleAttempts, ascensionActiveSpecSetting,
				sess.GUID)
		}
	}

	accountCharacters, _, err := CharacterListOrder(authDB, charDB, spec.Account, spec.Character)
	if err != nil {
		t.Fatalf("account character listing: %v", err)
	}

	writeResult(t, Result{
		Account: strings.ToUpper(spec.Account), Character: sess.Name, GUID: sess.GUID,
		Race: spec.Race, Class: spec.Class, Level: spec.Level, Spec: spec.Spec, GM: gm,
		Learned: spec.Learn, Equipped: spec.Items, Created: !exists,
		AccountCharacters: accountCharacters,
	})
}

// TestLabCharacterIndex reports the 0-based position of COA_LAB_CHARACTER_NAME in the account's
// character list, in the exact order the glue character-select screen displays it: CHAR_SEL_ENUM
// (CharacterDatabase.cpp) orders `ORDER BY COALESCE(c.order, c.guid)` and excludes deleted/inactive
// rows the same way. coa-client-lab login uses the index to navigate Up/Down before pressing Return,
// since the CHARACTER argument previously did nothing to steer on-screen selection.
// Run with: go test -run '^TestLabCharacterIndex$' -v
func TestLabCharacterIndex(t *testing.T) {
	account := os.Getenv("COA_LAB_CHARACTER_ACCOUNT")
	name := os.Getenv("COA_LAB_CHARACTER_NAME")
	if account == "" || name == "" {
		t.Fatalf("COA_LAB_CHARACTER_ACCOUNT and COA_LAB_CHARACTER_NAME are required")
	}

	authDB, err := e2eharness.OpenAuthDB()
	if err != nil {
		t.Fatalf("auth db: %v", err)
	}
	defer authDB.Close()
	charDB, err := e2eharness.OpenCharDB()
	if err != nil {
		t.Fatalf("char db: %v", err)
	}
	defer charDB.Close()

	names, index, err := CharacterListOrder(authDB, charDB, account, name)
	if err != nil {
		t.Fatalf("%v", err)
	}

	out := map[string]interface{}{"account": strings.ToUpper(account), "character": name, "names": names}
	if index >= 0 {
		out["index"] = index
		out["found"] = true
	} else {
		out["found"] = false
	}
	data, err := json.MarshalIndent(out, "", "  ")
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	outPath := os.Getenv("COA_LAB_CHARACTER_OUT")
	if outPath == "" {
		t.Fatalf("COA_LAB_CHARACTER_OUT is empty")
	}
	if err := os.WriteFile(outPath, append(data, '\n'), 0o600); err != nil {
		t.Fatalf("write result: %v", err)
	}
}

// CharacterListOrder returns account's character names in glue display order (see
// TestLabCharacterIndex) and the 0-based index of target (case-insensitive), or -1 if absent.
// No *testing.T: covered by an offline test against a fake in-memory sql.DB driver.
func CharacterListOrder(authDB, charDB *sql.DB, account, target string) (names []string, index int, err error) {
	var accountID int
	if err = authDB.QueryRow(`SELECT id FROM account WHERE username=?`, strings.ToUpper(account)).Scan(&accountID); err != nil {
		return nil, -1, fmt.Errorf("account %s: %w", account, err)
	}
	rows, err := charDB.Query(
		`SELECT c.name FROM characters AS c `+
			`LEFT JOIN character_ascension_state AS cas ON cas.guid = c.guid `+
			`WHERE c.account = ? AND c.deleteInfos_Name IS NULL AND (cas.active IS NULL OR cas.active <> 0) `+
			`ORDER BY COALESCE(c.order, c.guid)`,
		accountID,
	)
	if err != nil {
		return nil, -1, err
	}
	defer rows.Close()
	index = -1
	for rows.Next() {
		var name string
		if err = rows.Scan(&name); err != nil {
			return nil, -1, err
		}
		if strings.EqualFold(name, target) && index < 0 {
			index = len(names)
		}
		names = append(names, name)
	}
	return names, index, rows.Err()
}

// dedicatedAccountConflict returns the name of a character on account other than character
// itself, or "" if account holds no character yet or only character. Used to refuse a dedicated
// lab account (one coa-client-lab derived, meant to hold exactly one character) that already
// holds a different one. No *testing.T: covered by an offline test against the same fake
// sql.DB driver as CharacterListOrder.
func dedicatedAccountConflict(authDB, charDB *sql.DB, account, character string) (string, error) {
	names, _, err := CharacterListOrder(authDB, charDB, account, character)
	if err != nil {
		return "", err
	}
	for _, name := range names {
		if !strings.EqualFold(name, character) {
			return name, nil
		}
	}
	return "", nil
}

// SoapAdministratorLevel mirrors SEC_ADMINISTRATOR (src/common/Common.h:60 in the server repo),
// the security level CoAProbeRelay's `.labprobe` command table requires (src/server/coa/CoAProbeRelay.cpp,
// "send"/"result" children registered at SEC_ADMINISTRATOR): the SOAP account relay-setup prepares must
// hold this GM level on the slot's own auth DB, or the relay answers 401/403.
const SoapAdministratorLevel = 3

// TestLabSoapAccount creates or updates the SOAP account relay-setup uses, with SoapAdministratorLevel,
// reusing EnsureAccount/SetGM (the same account-creation path TestLabCharacterApply uses for lab
// characters) instead of raw SQL. No character is created: SOAP authentication only checks the
// account's username, password and GM level, never a character.
func TestLabSoapAccount(t *testing.T) {
	account := os.Getenv("COA_LAB_SOAP_ACCOUNT")
	password := os.Getenv("COA_LAB_SOAP_PASSWORD")
	if account == "" || password == "" {
		t.Fatalf("COA_LAB_SOAP_ACCOUNT and COA_LAB_SOAP_PASSWORD are required")
	}

	authDB, err := e2eharness.OpenAuthDB()
	if err != nil {
		t.Fatalf("auth db: %v", err)
	}
	defer authDB.Close()

	if err := e2eharness.EnsureAccount(authDB, account, password); err != nil {
		t.Fatalf("ensure account: %v", err)
	}
	if err := e2eharness.SetGM(authDB, account, SoapAdministratorLevel); err != nil {
		t.Fatalf("set gm: %v", err)
	}
}

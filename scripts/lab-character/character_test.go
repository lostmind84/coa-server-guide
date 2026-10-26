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
	if spec.Spec != 0 {
		bot.SetSpecialization(t, spec.Spec)
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
	bot.Save(t)

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

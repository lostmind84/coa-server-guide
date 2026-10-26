package labcharacter

import (
	"database/sql"
	"database/sql/driver"
	"errors"
	"fmt"
	"io"
	"testing"
)

// TestValidateClass is pure (no DB, no *testing.T plumbing into the Ghost harness) and runs offline:
// go test -run '^TestValidateClass$'
func TestValidateClass(t *testing.T) {
	cases := []struct {
		class uint8
		ok    bool
	}{
		{11, false}, // CLASS_DRUID: last non-CoA class
		{12, true},  // CLASS_BARBARIAN: first CoA class
		{23, true},  // CLASS_NECROMANCER
		{32, true},  // CLASS_SPIRIT_MAGE: last CoA class
		{33, false},
		{0, false},
		{1, false}, // CLASS_WARRIOR
	}
	for _, c := range cases {
		err := ValidateClass(c.class)
		if c.ok && err != nil {
			t.Errorf("class %d: want ok, got error: %v", c.class, err)
		}
		if !c.ok && err == nil {
			t.Errorf("class %d: want refused, got ok", c.class)
		}
	}
}

// --- fake sql/driver for CharacterListOrder, no network/DB needed ---

type fakeDriver struct{ rows map[string][][]driver.Value }

func (d fakeDriver) Open(name string) (driver.Conn, error) { return fakeConn{d, name}, nil }

type fakeConn struct {
	d    fakeDriver
	name string
}

func (c fakeConn) Prepare(query string) (driver.Stmt, error) {
	return fakeStmt{c.d, query}, nil
}
func (c fakeConn) Close() error              { return nil }
func (c fakeConn) Begin() (driver.Tx, error) { return nil, errors.New("not supported") }

type fakeStmt struct {
	d     fakeDriver
	query string
}

func (s fakeStmt) Close() error  { return nil }
func (s fakeStmt) NumInput() int { return -1 }
func (s fakeStmt) Exec(args []driver.Value) (driver.Result, error) {
	return nil, errors.New("not supported")
}
func (s fakeStmt) Query(args []driver.Value) (driver.Rows, error) {
	rows, ok := s.d.rows[s.query]
	if !ok {
		return nil, fmt.Errorf("fakeDriver: no rows registered for query %q", s.query)
	}
	return &fakeRows{rows: rows}, nil
}

type fakeRows struct {
	rows [][]driver.Value
	pos  int
}

func (r *fakeRows) Columns() []string { return []string{"col"} }
func (r *fakeRows) Close() error      { return nil }
func (r *fakeRows) Next(dest []driver.Value) error {
	if r.pos >= len(r.rows) {
		return io.EOF // driver.Rows.Next's end-of-data sentinel; sql.ErrNoRows is for QueryRow only
	}
	copy(dest, r.rows[r.pos])
	r.pos++
	return nil
}

// TestCharacterListOrder exercises the index lookup against a fake driver standing in for
// acore_auth/acore_characters: no real MySQL, no server, no network. Covers found, not-found
// and case-insensitive match.
func TestCharacterListOrder(t *testing.T) {
	const accountQuery = `SELECT id FROM account WHERE username=?`
	const charsQuery = `SELECT c.name FROM characters AS c LEFT JOIN character_ascension_state AS cas ON cas.guid = c.guid WHERE c.account = ? AND c.deleteInfos_Name IS NULL AND (cas.active IS NULL OR cas.active <> 0) ORDER BY COALESCE(c.order, c.guid)`

	authDriver := fakeDriver{rows: map[string][][]driver.Value{
		accountQuery: {{int64(7)}},
	}}
	charDriver := fakeDriver{rows: map[string][][]driver.Value{
		charsQuery: {{"Coalabone"}, {"Coalabnecro"}, {"Windwalker"}},
	}}
	sql.Register("labcharacter-fake-auth", authDriver)
	sql.Register("labcharacter-fake-char", charDriver)

	authDB, err := sql.Open("labcharacter-fake-auth", "")
	if err != nil {
		t.Fatalf("open auth: %v", err)
	}
	defer authDB.Close()
	charDB, err := sql.Open("labcharacter-fake-char", "")
	if err != nil {
		t.Fatalf("open char: %v", err)
	}
	defer charDB.Close()

	names, index, err := CharacterListOrder(authDB, charDB, "coalab1", "coalabnecro")
	if err != nil {
		t.Fatalf("CharacterListOrder: %v", err)
	}
	if index != 1 {
		t.Errorf("index = %d, want 1 (case-insensitive match on 2nd entry)", index)
	}
	wantNames := []string{"Coalabone", "Coalabnecro", "Windwalker"}
	if fmt.Sprint(names) != fmt.Sprint(wantNames) {
		t.Errorf("names = %v, want %v", names, wantNames)
	}

	_, missing, err := CharacterListOrder(authDB, charDB, "coalab1", "Nobody")
	if err != nil {
		t.Fatalf("CharacterListOrder (missing): %v", err)
	}
	if missing != -1 {
		t.Errorf("index for absent character = %d, want -1", missing)
	}
}

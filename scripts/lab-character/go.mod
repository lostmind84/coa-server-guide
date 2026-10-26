module coalab/labcharacter

go 1.26

require (
	github.com/azerothcore/AzerothGhost v0.0.0
	github.com/go-sql-driver/mysql v1.10.0
)

// This replace is the only one that is user-specific (a local checkout path) and is therefore
// supplied at run time via a generated go.work file (GOWORK=...), not hard-coded here: see
// run_lab_character() in coa-client-lab. The detour-go fork below is a public replace the
// upstream AzerothGhost go.mod also carries; a dependency's own replace directives are not
// honored when it is used as a dependency, so consumers must repeat it.
replace github.com/o0olele/detour-go => github.com/walkline/detour-go v0.0.0-20260624174442-8056537019f8

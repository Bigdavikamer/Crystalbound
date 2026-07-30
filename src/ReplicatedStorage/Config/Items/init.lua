--!strict
--[[
	Items

	Index of every item definition source. Data only.

	Returns a map of source name to definition table rather than a merged table,
	so ItemRegistry can name the file a problem came from - "duplicate Id
	'pick_starter' in Equipment" is a far more useful boot error than "duplicate
	Id 'pick_starter'".

	Merging, duplicate detection and validation all happen in ItemRegistry, so
	there is exactly one validation authority.

	Adding a category is one file plus one line here.
]]

return {
	Materials = require(script.Materials),
	Equipment = require(script.Equipment),
}

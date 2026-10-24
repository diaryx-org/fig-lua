//! Lua values to and from [`serde_json::Value`], which is the JSON the helper
//! wire carries — so a script's tables are the wire's shapes, and the crate
//! converts rather than interprets.
//!
//! A Lua table with only the keys `1..n` is a sequence; any other table is
//! a map with its string keys (a non-string key is refused — the wire has
//! none). `nil` has no place in a table, so an absent field is an absent
//! JSON field, which every reader on the fig side treats as `null`. A number
//! JSON cannot hold (a NaN or an infinity) is refused, since no wire carries
//! it.

use fig::language::LanguageError;
use mlua::{Lua, Table};
use serde_json::{Map, Number, Value};

/// A Lua value as a `serde_json::Value`.
pub fn lua_to_value(v: &mlua::Value) -> Result<Value, LanguageError> {
    Ok(match v {
        mlua::Value::Nil => Value::Null,
        mlua::Value::Boolean(b) => Value::Bool(*b),
        mlua::Value::Integer(n) => Value::Number(Number::from(*n)),
        mlua::Value::Number(n) => match Number::from_f64(*n) {
            Some(n) => Value::Number(n),
            None => {
                return Err(LanguageError::new(format!(
                    "{n} has no place in a node table or description: JSON has no such number"
                )));
            }
        },
        mlua::Value::String(s) => Value::String(s.to_str().map_err(lua_err)?.to_string()),
        mlua::Value::Table(t) => table_to_value(t)?,
        // A function in the module table is the format's code, not its
        // description; it is left out rather than refused.
        mlua::Value::Function(_) => Value::Null,
        other => {
            return Err(LanguageError::new(format!(
                "a {} has no place in a node table or description",
                other.type_name()
            )));
        }
    })
}

fn table_to_value(t: &Table) -> Result<Value, LanguageError> {
    let len = t.raw_len();
    let mut entries = 0usize;
    let mut sequence = true;
    let mut map = Map::new();
    for pair in t.clone().pairs::<mlua::Value, mlua::Value>() {
        let (k, v) = pair.map_err(lua_err)?;
        entries += 1;
        match &k {
            mlua::Value::Integer(i) if *i >= 1 && (*i as usize) <= len => {}
            mlua::Value::String(s) => {
                sequence = false;
                let value = lua_to_value(&v)?;
                if !matches!(value, Value::Null) {
                    map.insert(s.to_str().map_err(lua_err)?.to_string(), value);
                }
            }
            other => {
                return Err(LanguageError::new(format!(
                    "a table key must be a string or a sequence index, not {}",
                    other.type_name()
                )));
            }
        }
    }
    if sequence && entries == len {
        let mut seq = Vec::with_capacity(len);
        for i in 1..=len {
            let v: mlua::Value = t.raw_get(i).map_err(lua_err)?;
            seq.push(lua_to_value(&v)?);
        }
        return Ok(Value::Array(seq));
    }
    if sequence {
        return Err(LanguageError::new(
            "a table with integer keys that are not 1..n is neither a sequence nor a map",
        ));
    }
    if len > 0 {
        return Err(LanguageError::new(
            "a table mixes sequence indices and string keys",
        ));
    }
    Ok(Value::Object(map))
}

/// A `serde_json::Value` as a Lua value. `Null` becomes `nil`, so a null map entry
/// is an absent key.
pub fn value_to_lua(lua: &Lua, v: &Value) -> Result<mlua::Value, LanguageError> {
    Ok(match v {
        Value::Null => mlua::Value::Nil,
        Value::Bool(b) => mlua::Value::Boolean(*b),
        Value::Number(n) => match n.as_i64() {
            Some(i) => mlua::Value::Integer(i),
            // A `u64` past `i64::MAX`, or a float.
            None => mlua::Value::Number(n.as_f64().unwrap_or(f64::NAN)),
        },
        Value::String(s) => mlua::Value::String(lua.create_string(s).map_err(lua_err)?),
        Value::Array(items) => {
            let t = lua
                .create_table_with_capacity(items.len(), 0)
                .map_err(lua_err)?;
            for (i, item) in items.iter().enumerate() {
                t.raw_set(i + 1, value_to_lua(lua, item)?)
                    .map_err(lua_err)?;
            }
            mlua::Value::Table(t)
        }
        Value::Object(entries) => {
            let t = lua
                .create_table_with_capacity(0, entries.len())
                .map_err(lua_err)?;
            for (k, v) in entries {
                let value = value_to_lua(lua, v)?;
                if !matches!(value, mlua::Value::Nil) {
                    t.raw_set(k.as_str(), value).map_err(lua_err)?;
                }
            }
            mlua::Value::Table(t)
        }
    })
}

fn lua_err(e: mlua::Error) -> LanguageError {
    LanguageError::new(e.to_string())
}

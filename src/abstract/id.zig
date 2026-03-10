pub const Id = u64;

var _global_id_counter: Id = 0;
pub fn getId() Id {
    _global_id_counter += 1;
    return _global_id_counter;
}

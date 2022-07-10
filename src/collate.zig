const std = @import("std");
const Allocator = std.mem.Allocator;
const metadata_namespace = @import("metadata.zig");
const Metadata = metadata_namespace.Metadata;
const AllMetadata = metadata_namespace.AllMetadata;
const MetadataType = metadata_namespace.MetadataType;
const TypedMetadata = metadata_namespace.TypedMetadata;
const id3v2_data = @import("id3v2_data.zig");
const ziglyph = @import("ziglyph");
const windows1251 = @import("windows1251.zig");
const latin1 = @import("latin1.zig");
const fields = @import("fields.zig");

pub const Collator = struct {
    metadata: *AllMetadata,
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    config: Config,
    tag_indexes_by_priority: []usize,

    const Self = @This();

    pub const Config = struct {
        prioritization: Prioritization = default_prioritization,
        duplicate_tag_strategy: DuplicateTagStrategy = .prioritize_best,

        pub const DuplicateTagStrategy = enum {
            /// Use a heuristic to prioritize the 'best' tag for any tag types with multiple tags,
            /// and fall back to second best, etc.
            ///
            /// TODO: Improve the heuristic; right now it uses largest number of fields in the tag.
            prioritize_best,
            /// Always prioritize the first tag for each tag type, and fall back
            /// to subsequent tags of that type (in file order)
            ///
            /// Note: This is how ffmpeg/libavformat handles duplicate ID3v2 tags.
            prioritize_first,
            /// Only look at the first tag (in file order) for each tag type, ignoring all
            /// duplicate tags entirely.
            ///
            /// Note: This is how TagLib handles duplicate ID3v2 tags.
            ignore_duplicates,
        };
    };

    pub fn init(allocator: Allocator, metadata: *AllMetadata, config: Config) !Self {
        var collator = Self{
            .metadata = metadata,
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .config = config,
            .tag_indexes_by_priority = &[_]usize{},
        };
        switch (config.duplicate_tag_strategy) {
            .prioritize_best => {
                collator.tag_indexes_by_priority = try collator.arena.allocator().alloc(usize, metadata.tags.len);
                determineBestTagPriorities(metadata, config.prioritization, collator.tag_indexes_by_priority);
            },
            .prioritize_first => {
                collator.tag_indexes_by_priority = try collator.arena.allocator().alloc(usize, metadata.tags.len);
                determineFileOrderTagPriorities(metadata, config.prioritization, collator.tag_indexes_by_priority, .include_duplicates);
            },
            .ignore_duplicates => {
                const count_ignoring_duplicates = metadata.countIgnoringDuplicates();
                collator.tag_indexes_by_priority = try collator.arena.allocator().alloc(usize, count_ignoring_duplicates);
                determineFileOrderTagPriorities(metadata, config.prioritization, collator.tag_indexes_by_priority, .ignore_duplicates);
            },
        }
        return collator;
    }

    pub fn deinit(self: *Self) void {
        self.arena.deinit();
    }

    fn determineBestTagPriorities(metadata: *AllMetadata, prioritization: Prioritization, tag_indexes_by_priority: []usize) void {
        var priority_index: usize = 0;
        for (prioritization.order) |metadata_type| {
            const first_index = priority_index;
            var meta_index_it = metadata.metadataOfTypeIndexIterator(metadata_type);
            while (meta_index_it.next()) |meta_index| {
                // For each tag of the current type, we compare backwards with all
                // tags of the same type that have been inserted already and find
                // its insertion point in prioritization order. We then shift things
                // forward as needed in order to insert the current tag into the
                // correct place.
                var insertion_index = priority_index;
                if (priority_index > first_index) {
                    const meta = &metadata.tags[meta_index];
                    var compare_index = priority_index - 1;
                    while (compare_index >= first_index) {
                        const compare_meta_index = tag_indexes_by_priority[compare_index];
                        const compare_meta = &metadata.tags[compare_meta_index];
                        if (compareTagsForPrioritization(meta, compare_meta) == .gt) {
                            insertion_index = compare_index;
                        }
                        if (compare_index == 0) break;
                        compare_index -= 1;
                    }
                    if (insertion_index != priority_index) {
                        var to_shift = tag_indexes_by_priority[insertion_index..priority_index];
                        var dest = tag_indexes_by_priority[insertion_index + 1 .. priority_index + 1];
                        std.mem.copyBackwards(usize, dest, to_shift);
                    }
                }
                tag_indexes_by_priority[insertion_index] = meta_index;
                priority_index += 1;
            }
        }
        std.debug.assert(priority_index == tag_indexes_by_priority.len);
    }

    fn determineFileOrderTagPriorities(metadata: *AllMetadata, prioritization: Prioritization, tag_indexes_by_priority: []usize, duplicate_handling: enum { include_duplicates, ignore_duplicates }) void {
        var priority_index: usize = 0;
        for (prioritization.order) |metadata_type| {
            var meta_index_it = metadata.metadataOfTypeIndexIterator(metadata_type);
            while (meta_index_it.next()) |meta_index| {
                tag_indexes_by_priority[priority_index] = meta_index;
                priority_index += 1;
                if (duplicate_handling == .ignore_duplicates) {
                    break;
                }
            }
        }
        std.debug.assert(priority_index == tag_indexes_by_priority.len);
    }

    fn compareTagsForPrioritization(a: *const TypedMetadata, b: *const TypedMetadata) std.math.Order {
        const a_count = fieldCountForPrioritization(a);
        const b_count = fieldCountForPrioritization(b);
        return std.math.order(a_count, b_count);
    }

    fn fieldCountForPrioritization(meta: *const TypedMetadata) usize {
        switch (meta.*) {
            .id3v1 => return meta.id3v1.map.entries.items.len,
            .id3v2 => return meta.id3v2.metadata.map.entries.items.len,
            .flac => return meta.flac.map.entries.items.len,
            .vorbis => return meta.vorbis.map.entries.items.len,
            .ape => return meta.ape.metadata.map.entries.items.len,
            .mp4 => return meta.mp4.map.entries.items.len,
        }
    }

    /// Returns a single value gotten from the tag with the highest priority,
    /// or null if no values exist for the relevant keys in any of the tags.
    pub fn getPrioritizedValue(self: *Self, keys: [MetadataType.num_types]?[]const u8) ?[]const u8 {
        for (self.tag_indexes_by_priority) |tag_index| {
            const tag = &self.metadata.tags[tag_index];
            const key = keys[@enumToInt(std.meta.activeTag(tag.*))] orelse continue;
            const value = tag.getMetadata().map.getFirst(key) orelse continue;
            // TODO: Need to do trimming, character encoding conversions, etc here
            //       (see CollatedTextSet)
            return value;
        }
        return null;
    }

    fn addValuesToSet(set: *CollatedTextSet, tag: *TypedMetadata, keys: [MetadataType.num_types]?[]const u8) !void {
        const key = keys[@enumToInt(std.meta.activeTag(tag.*))] orelse return;
        switch (tag.*) {
            .id3v1 => |*id3v1_meta| {
                if (id3v1_meta.map.getFirst(key)) |value| {
                    try set.put(value);
                }
            },
            .flac => |*flac_meta| {
                var value_it = flac_meta.map.valueIterator(key);
                while (value_it.next()) |value| {
                    try set.put(value);
                }
            },
            .vorbis => |*vorbis_meta| {
                var value_it = vorbis_meta.map.valueIterator(key);
                while (value_it.next()) |value| {
                    try set.put(value);
                }
            },
            .id3v2 => |*id3v2_meta| {
                var value_it = id3v2_meta.metadata.map.valueIterator(key);
                while (value_it.next()) |value| {
                    try set.put(value);
                }
            },
            .ape => |*ape_meta| {
                var value_it = ape_meta.metadata.map.valueIterator(key);
                while (value_it.next()) |value| {
                    try set.put(value);
                }
            },
            .mp4 => |*mp4_meta| {
                var value_it = mp4_meta.map.valueIterator(key);
                while (value_it.next()) |value| {
                    try set.put(value);
                }
            },
        }
    }

    pub fn getValuesFromKeys(self: *Self, keys: [MetadataType.num_types]?[]const u8) ![][]const u8 {
        var set = CollatedTextSet.init(self.arena.allocator());
        defer set.deinit();

        for (self.config.prioritization.order) |meta_type| {
            const is_last_resort = self.config.prioritization.priority(meta_type) == .last_resort;
            if (!is_last_resort or set.count() == 0) {
                var meta_it = self.metadata.metadataOfTypeIterator(meta_type);
                while (meta_it.next()) |meta| {
                    try addValuesToSet(&set, meta, keys);
                }
            }
        }
        return try self.arena.allocator().dupe([]const u8, set.values.items);
    }

    pub fn artists(self: *Self) ![][]const u8 {
        return self.getValuesFromKeys(fields.artist);
    }

    pub fn albums(self: *Self) ![][]const u8 {
        return self.getValuesFromKeys(fields.album);
    }

    pub fn album(self: *Self) ?[]const u8 {
        return self.getPrioritizedValue(fields.album);
    }

    pub fn titles(self: *Self) ?[][]const u8 {
        return self.getValuesFromKeys(fields.title);
    }

    pub fn title(self: *Self) ?[]const u8 {
        return self.getPrioritizedValue(fields.title);
    }
};

pub const Prioritization = struct {
    order: [MetadataType.num_types]MetadataType,
    priorities: [MetadataType.num_types]Priority,

    pub const Priority = enum {
        normal,
        last_resort,
    };

    pub fn priority(self: Prioritization, meta_type: MetadataType) Priority {
        return self.priorities[@enumToInt(meta_type)];
    }
};

pub const default_prioritization = Prioritization{
    .order = [_]MetadataType{ .mp4, .flac, .vorbis, .id3v2, .ape, .id3v1 },
    .priorities = init: {
        var priorities = [_]Prioritization.Priority{.normal} ** MetadataType.num_types;
        priorities[@enumToInt(MetadataType.id3v1)] = .last_resort;
        break :init priorities;
    },
};

test "prioritization last resort" {
    var allocator = std.testing.allocator;
    var metadata_buf = std.ArrayList(TypedMetadata).init(allocator);
    defer metadata_buf.deinit();

    try metadata_buf.append(TypedMetadata{ .id3v2 = .{
        .metadata = Metadata.init(allocator),
        .user_defined = metadata_namespace.MetadataMap.init(allocator),
        .header = undefined,
        .comments = id3v2_data.FullTextMap.init(allocator),
        .unsynchronized_lyrics = id3v2_data.FullTextMap.init(allocator),
    } });
    try metadata_buf.items[0].id3v2.metadata.map.put("TPE1", "test");

    try metadata_buf.append(TypedMetadata{ .id3v1 = Metadata.init(allocator) });
    try metadata_buf.items[1].id3v1.map.put("artist", "ignored");

    var all = AllMetadata{
        .allocator = allocator,
        .tags = metadata_buf.toOwnedSlice(),
    };
    defer all.deinit();

    var collator = try Collator.init(allocator, &all, .{});
    defer collator.deinit();

    const artists = try collator.artists();
    try std.testing.expectEqual(@as(usize, 1), artists.len);
    try std.testing.expectEqualStrings("test", artists[0]);
}

test "prioritization flac > ape" {
    var allocator = std.testing.allocator;
    var metadata_buf = std.ArrayList(TypedMetadata).init(allocator);
    defer metadata_buf.deinit();

    // flac is prioritized over ape, so for duplicate keys the flac casing
    // should end up in the result even if ape comes first in the file

    try metadata_buf.append(TypedMetadata{ .ape = .{
        .metadata = Metadata.init(allocator),
        .header_or_footer = undefined,
    } });
    try metadata_buf.items[0].ape.metadata.map.put("Artist", "FLACcase");

    try metadata_buf.append(TypedMetadata{ .flac = Metadata.init(allocator) });
    try metadata_buf.items[1].flac.map.put("ARTIST", "FlacCase");

    var all = AllMetadata{
        .allocator = allocator,
        .tags = metadata_buf.toOwnedSlice(),
    };
    defer all.deinit();

    var collator = try Collator.init(allocator, &all, .{});
    defer collator.deinit();

    const artists = try collator.artists();
    try std.testing.expectEqual(@as(usize, 1), artists.len);
    try std.testing.expectEqualStrings("FlacCase", artists[0]);
}

test "prioritize_best for single values" {
    var allocator = std.testing.allocator;
    var metadata_buf = std.ArrayList(TypedMetadata).init(allocator);
    defer metadata_buf.deinit();

    try metadata_buf.append(TypedMetadata{ .ape = .{
        .metadata = Metadata.init(allocator),
        .header_or_footer = undefined,
    } });
    try metadata_buf.items[0].ape.metadata.map.put("Album", "ape album");

    try metadata_buf.append(TypedMetadata{ .flac = Metadata.init(allocator) });
    try metadata_buf.items[1].flac.map.put("ALBUM", "bad album");

    try metadata_buf.append(TypedMetadata{ .flac = Metadata.init(allocator) });
    try metadata_buf.items[2].flac.map.put("ALBUM", "good album");
    try metadata_buf.items[2].flac.map.put("ARTIST", "artist");

    try metadata_buf.append(TypedMetadata{ .flac = Metadata.init(allocator) });
    try metadata_buf.items[3].flac.map.put("ALBUM", "best album");
    try metadata_buf.items[3].flac.map.put("ARTIST", "artist");
    try metadata_buf.items[3].flac.map.put("TITLE", "song");

    var all = AllMetadata{
        .allocator = allocator,
        .tags = metadata_buf.toOwnedSlice(),
    };
    defer all.deinit();

    var collator = try Collator.init(allocator, &all, .{
        .duplicate_tag_strategy = .prioritize_best,
    });
    defer collator.deinit();

    const album = collator.album();
    try std.testing.expectEqualStrings("best album", album.?);
}

test "prioritize_first for single values" {
    var allocator = std.testing.allocator;
    var metadata_buf = std.ArrayList(TypedMetadata).init(allocator);
    defer metadata_buf.deinit();

    try metadata_buf.append(TypedMetadata{ .ape = .{
        .metadata = Metadata.init(allocator),
        .header_or_footer = undefined,
    } });
    try metadata_buf.items[0].ape.metadata.map.put("Album", "ape album");

    try metadata_buf.append(TypedMetadata{ .flac = Metadata.init(allocator) });
    try metadata_buf.items[1].flac.map.put("ALBUM", "first album");

    try metadata_buf.append(TypedMetadata{ .flac = Metadata.init(allocator) });
    try metadata_buf.items[2].flac.map.put("ALBUM", "second album");
    try metadata_buf.items[2].flac.map.put("TITLE", "title");

    var all = AllMetadata{
        .allocator = allocator,
        .tags = metadata_buf.toOwnedSlice(),
    };
    defer all.deinit();

    var collator = try Collator.init(allocator, &all, .{
        .duplicate_tag_strategy = .prioritize_first,
    });
    defer collator.deinit();

    const album = collator.album();
    try std.testing.expectEqualStrings("first album", album.?);

    // should get the title from the second FLAC tag
    const title = collator.title();
    try std.testing.expectEqualStrings("title", title.?);
}

test "ignore_duplicates for single values" {
    var allocator = std.testing.allocator;
    var metadata_buf = std.ArrayList(TypedMetadata).init(allocator);
    defer metadata_buf.deinit();

    try metadata_buf.append(TypedMetadata{ .ape = .{
        .metadata = Metadata.init(allocator),
        .header_or_footer = undefined,
    } });
    try metadata_buf.items[0].ape.metadata.map.put("Album", "ape album");

    try metadata_buf.append(TypedMetadata{ .flac = Metadata.init(allocator) });
    try metadata_buf.items[1].flac.map.put("ALBUM", "first album");

    try metadata_buf.append(TypedMetadata{ .flac = Metadata.init(allocator) });
    try metadata_buf.items[2].flac.map.put("ALBUM", "second album");
    try metadata_buf.items[2].flac.map.put("TITLE", "title");

    var all = AllMetadata{
        .allocator = allocator,
        .tags = metadata_buf.toOwnedSlice(),
    };
    defer all.deinit();

    var collator = try Collator.init(allocator, &all, .{
        .duplicate_tag_strategy = .ignore_duplicates,
    });
    defer collator.deinit();

    const album = collator.album();
    try std.testing.expectEqualStrings("first album", album.?);

    // should ignore the second FLAC tag, so shouldn't find a title
    const title = collator.title();
    try std.testing.expect(title == null);
}

/// Set that:
/// - Trims spaces and NUL from both sides of inputs
/// - Converts inputs to inferred character encodings (e.g. Windows-1251)
/// - De-duplicates via UTF-8 normalization and case normalization
/// - Ignores empty values
///
/// Canonical values in the set are stored in an ArrayList
///
/// TODO: Maybe startsWith detection of some kind (but this might lead to false positives)
const CollatedTextSet = struct {
    values: std.ArrayListUnmanaged([]const u8),
    // TODO: Maybe do case-insensitivity/normalization during
    //       hash/eql instead
    normalized_set: std.StringHashMapUnmanaged(usize),
    arena: Allocator,

    const Self = @This();

    /// Allocator must be an arena that will get cleaned up outside of
    /// this struct (this struct's deinit will not handle cleaning up the arena)
    pub fn init(arena: Allocator) Self {
        return .{
            .values = std.ArrayListUnmanaged([]const u8){},
            .normalized_set = std.StringHashMapUnmanaged(usize){},
            .arena = arena,
        };
    }

    pub fn deinit(self: *Self) void {
        // TODO: If this uses an arena, this isn't necessary
        self.values.deinit(self.arena);
        self.normalized_set.deinit(self.arena);
    }

    pub fn put(self: *Self, value: []const u8) !void {
        const trimmed = std.mem.trim(u8, value, " \x00");
        if (trimmed.len == 0) return;

        var translated: ?[]u8 = null;
        if (latin1.isUtf8AllLatin1(trimmed) and windows1251.couldBeWindows1251(trimmed)) {
            const extended_ascii_str = try latin1.utf8ToLatin1Alloc(self.arena, trimmed);
            translated = try windows1251.windows1251ToUtf8Alloc(self.arena, extended_ascii_str);
        }
        const lowered = try ziglyph.toCaseFoldStr(self.arena, translated orelse trimmed);

        var normalizer = try ziglyph.Normalizer.init(self.arena);
        defer normalizer.deinit();

        const normalized = try normalizer.normalizeTo(.canon, lowered);
        const result = try self.normalized_set.getOrPut(self.arena, normalized);
        if (!result.found_existing) {
            // We need to dupe the normalized version of the string when
            // storing it because ziglyph.Normalizer creates an arena and
            // destroys the arena on normalizer.deinit(), which would
            // destroy the normalized version of the string that was
            // used as the key for the normalized_set.
            result.key_ptr.* = try self.arena.dupe(u8, normalized);

            const index = self.values.items.len;
            try self.values.append(self.arena, translated orelse trimmed);
            result.value_ptr.* = index;
        }
    }

    pub fn count(self: Self) usize {
        return self.values.items.len;
    }
};

test "CollatedTextSet utf-8 case-insensitivity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var set = CollatedTextSet.init(arena.allocator());
    defer set.deinit();

    try set.put("something");
    try set.put("someTHING");

    try std.testing.expectEqual(@as(usize, 1), set.count());

    try set.put("cyriLLic И");
    try set.put("cyrillic и");

    try std.testing.expectEqual(@as(usize, 2), set.count());
}

test "CollatedTextSet utf-8 normalization" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var set = CollatedTextSet.init(arena.allocator());
    defer set.deinit();

    try set.put("foé");
    try set.put("foe\u{0301}");

    try std.testing.expectEqual(@as(usize, 1), set.count());
}

test "CollatedTextSet windows-1251 detection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var set = CollatedTextSet.init(arena.allocator());
    defer set.deinit();

    // Note: the Latin-1 bytes here are "\xC0\xEF\xEE\xF1\xF2\xF0\xEE\xF4"
    try set.put("Àïîñòðîô");

    try std.testing.expectEqualStrings("Апостроф", set.values.items[0]);

    try set.put("АПОСТРОФ");
    try std.testing.expectEqual(@as(usize, 1), set.count());
}

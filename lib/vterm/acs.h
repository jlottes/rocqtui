/* VT100-style Alternate Character Set Data */

#define ACS_MAP_LOW_START 0x2b  /* '+' */
#define ACS_MAP_LOW_N     4
extern const uint32 acs_map_low[ACS_MAP_LOW_N];

#define ACS_MAP_HIGH_START 0x60  /* '`' */
#define ACS_MAP_HIGH_N     0x20
extern const uint32 acs_map_high[ACS_MAP_HIGH_N];

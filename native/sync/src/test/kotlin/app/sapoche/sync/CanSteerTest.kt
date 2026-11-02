package app.sapoche.sync

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class CanSteerTest {
    private fun snapshot(
        guestControl: String = "all",
        ownerId: String? = "owner",
        you: String? = "guest",
        ownerAway: Boolean = false,
        solo: Boolean = false,
    ) = GroupSession.Snapshot(
        state = RoomState(emptyList(), 0, "idle", 0, 0, 1, ownerId = ownerId, guestControl = guestControl),
        members = listOf(Member("owner", "Owner", true, owner = true, away = ownerAway), Member("guest", "Guest", true)),
        you = you,
        solo = solo,
    )

    @Test
    fun outsideARoomEverythingIsAllowed() {
        assertTrue(GroupSession.Snapshot().canSteer)
    }

    @Test
    fun aGuestMaySteerWhenGuestsAreFree() {
        assertTrue(snapshot(guestControl = "all").canSteer)
    }

    @Test
    fun aGuestMayNotSteerWhileTheOwnerIsHereAndGuestsOnlyAdd() {
        assertFalse(snapshot(guestControl = "add").canSteer)
    }

    @Test
    fun theOwnerAlwaysMaySteer() {
        assertTrue(snapshot(guestControl = "add", you = "owner").canSteer)
    }

    @Test
    fun aGuestMaySteerOnceTheOwnerIsAway() {
        assertTrue(snapshot(guestControl = "add", ownerAway = true).canSteer)
    }

    @Test
    fun listeningAloneIsNotTheRoomsToRefuse() {
        assertTrue(snapshot(guestControl = "add", solo = true).canSteer)
    }
}

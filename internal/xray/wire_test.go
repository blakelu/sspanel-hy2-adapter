package xray

import (
	"reflect"
	"testing"

	"google.golang.org/protobuf/encoding/protowire"
)

func TestWireCodecDecodesInboundUsers(t *testing.T) {
	account := appendString(nil, 1, "user-uuid")
	account = appendString(account, 2, visionFlow)
	user := appendString(nil, 2, "12")
	user = appendMessage(user, 3, marshalTypedMessage(typedMessage{Type: vlessAccountType, Value: account}))
	responseData := appendMessage(nil, 1, user)

	var response getInboundUsersResponse
	if err := (wireCodec{}).Unmarshal(responseData, &response); err != nil {
		t.Fatal(err)
	}
	want := []wireUser{{Email: "12", Account: wireAccount{Type: vlessAccountType, ID: "user-uuid", Flow: visionFlow}}}
	if !reflect.DeepEqual(response.Users, want) {
		t.Fatalf("users = %#v, want %#v", response.Users, want)
	}
}

func TestWireCodecDecodesStats(t *testing.T) {
	stat := appendString(nil, 1, "user>>>12>>>traffic>>>uplink")
	stat = protowire.AppendTag(stat, 2, protowire.VarintType)
	stat = protowire.AppendVarint(stat, 456)
	responseData := appendMessage(nil, 1, stat)

	var response queryStatsResponse
	if err := (wireCodec{}).Unmarshal(responseData, &response); err != nil {
		t.Fatal(err)
	}
	want := []wireStat{{Name: "user>>>12>>>traffic>>>uplink", Value: 456}}
	if !reflect.DeepEqual(response.Stats, want) {
		t.Fatalf("stats = %#v, want %#v", response.Stats, want)
	}
}

func TestWireCodecRejectsMalformedResponse(t *testing.T) {
	var response queryStatsResponse
	if err := (wireCodec{}).Unmarshal([]byte{0xff}, &response); err == nil {
		t.Fatal("expected malformed protobuf error")
	}
}

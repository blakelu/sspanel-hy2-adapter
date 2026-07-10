package xray

import (
	"fmt"

	"google.golang.org/protobuf/encoding/protowire"
)

// These small wire types cover only the Xray gRPC messages used by the
// adapter. Keeping them local avoids linking the complete Xray core into this
// sidecar solely for generated protobuf declarations.
type getInboundUsersRequest struct{ Tag string }
type getInboundUsersResponse struct{ Users []wireUser }
type alterInboundRequest struct {
	Tag       string
	Operation typedMessage
}
type queryStatsRequest struct{ Pattern string }
type queryStatsResponse struct{ Stats []wireStat }
type emptyResponse struct{}
type typedMessage struct {
	Type  string
	Value []byte
}
type wireUser struct {
	Email   string
	Account wireAccount
}
type wireAccount struct {
	Type string
	ID   string
	Flow string
}
type wireStat struct {
	Name  string
	Value int64
}

type wireCodec struct{}

func (wireCodec) Name() string { return "proto" }

func (wireCodec) Marshal(value any) ([]byte, error) {
	switch message := value.(type) {
	case *getInboundUsersRequest:
		return appendString(nil, 1, message.Tag), nil
	case *alterInboundRequest:
		b := appendString(nil, 1, message.Tag)
		return appendMessage(b, 2, marshalTypedMessage(message.Operation)), nil
	case *queryStatsRequest:
		return appendString(nil, 1, message.Pattern), nil
	default:
		return nil, fmt.Errorf("unsupported Xray request type %T", value)
	}
}

func (wireCodec) Unmarshal(data []byte, value any) error {
	switch message := value.(type) {
	case *getInboundUsersResponse:
		return unmarshalInboundUsers(data, message)
	case *queryStatsResponse:
		return unmarshalQueryStats(data, message)
	case *emptyResponse:
		return nil
	default:
		return fmt.Errorf("unsupported Xray response type %T", value)
	}
}

func marshalAddUserOperation(user wireUser) []byte {
	account := appendString(nil, 1, user.Account.ID)
	account = appendString(account, 2, user.Account.Flow)
	accountMessage := marshalTypedMessage(typedMessage{Type: user.Account.Type, Value: account})
	userMessage := appendString(nil, 2, user.Email)
	userMessage = appendMessage(userMessage, 3, accountMessage)
	return appendMessage(nil, 1, userMessage)
}

func marshalRemoveUserOperation(email string) []byte { return appendString(nil, 1, email) }

func marshalTypedMessage(message typedMessage) []byte {
	b := appendString(nil, 1, message.Type)
	return appendMessage(b, 2, message.Value)
}

func unmarshalInboundUsers(data []byte, response *getInboundUsersResponse) error {
	return consumeFields(data, func(number protowire.Number, typ protowire.Type, value []byte) error {
		if number != 1 || typ != protowire.BytesType {
			return nil
		}
		user := wireUser{}
		if err := consumeFields(value, func(number protowire.Number, typ protowire.Type, value []byte) error {
			switch {
			case number == 2 && typ == protowire.BytesType:
				user.Email = string(value)
			case number == 3 && typ == protowire.BytesType:
				message, err := unmarshalTypedMessage(value)
				if err != nil {
					return err
				}
				user.Account.Type = message.Type
				if message.Type == vlessAccountType {
					if err := consumeFields(message.Value, func(number protowire.Number, typ protowire.Type, value []byte) error {
						switch {
						case number == 1 && typ == protowire.BytesType:
							user.Account.ID = string(value)
						case number == 2 && typ == protowire.BytesType:
							user.Account.Flow = string(value)
						}
						return nil
					}); err != nil {
						return err
					}
				}
			}
			return nil
		}); err != nil {
			return err
		}
		response.Users = append(response.Users, user)
		return nil
	})
}

func unmarshalTypedMessage(data []byte) (typedMessage, error) {
	message := typedMessage{}
	err := consumeFields(data, func(number protowire.Number, typ protowire.Type, value []byte) error {
		switch {
		case number == 1 && typ == protowire.BytesType:
			message.Type = string(value)
		case number == 2 && typ == protowire.BytesType:
			message.Value = append([]byte(nil), value...)
		}
		return nil
	})
	return message, err
}

func unmarshalQueryStats(data []byte, response *queryStatsResponse) error {
	return consumeFields(data, func(number protowire.Number, typ protowire.Type, value []byte) error {
		if number != 1 || typ != protowire.BytesType {
			return nil
		}
		stat := wireStat{}
		if err := consumeFields(value, func(number protowire.Number, typ protowire.Type, value []byte) error {
			switch {
			case number == 1 && typ == protowire.BytesType:
				stat.Name = string(value)
			case number == 2 && typ == protowire.VarintType:
				parsed, n := protowire.ConsumeVarint(value)
				if n < 0 {
					return protowire.ParseError(n)
				}
				stat.Value = int64(parsed)
			}
			return nil
		}); err != nil {
			return err
		}
		response.Stats = append(response.Stats, stat)
		return nil
	})
}

func consumeFields(data []byte, consume func(protowire.Number, protowire.Type, []byte) error) error {
	for len(data) > 0 {
		number, typ, n := protowire.ConsumeTag(data)
		if n < 0 {
			return protowire.ParseError(n)
		}
		data = data[n:]
		var value []byte
		var consumed int
		switch typ {
		case protowire.BytesType:
			value, consumed = protowire.ConsumeBytes(data)
		case protowire.VarintType:
			_, consumed = protowire.ConsumeVarint(data)
			value = data[:max(consumed, 0)]
		default:
			consumed = protowire.ConsumeFieldValue(number, typ, data)
		}
		if consumed < 0 {
			return protowire.ParseError(consumed)
		}
		if err := consume(number, typ, value); err != nil {
			return err
		}
		data = data[consumed:]
	}
	return nil
}

func appendString(data []byte, number protowire.Number, value string) []byte {
	if value == "" {
		return data
	}
	data = protowire.AppendTag(data, number, protowire.BytesType)
	return protowire.AppendString(data, value)
}

func appendMessage(data []byte, number protowire.Number, value []byte) []byte {
	data = protowire.AppendTag(data, number, protowire.BytesType)
	return protowire.AppendBytes(data, value)
}

package xray

import (
	"context"
	"fmt"
	"strconv"
	"strings"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"

	"sspanel-uim-hy2-adapter/internal/traffic"
)

const (
	visionFlow           = "xtls-rprx-vision"
	handlerService       = "/xray.app.proxyman.command.HandlerService/"
	statsService         = "/xray.app.stats.command.StatsService/"
	vlessAccountType     = "xray.proxy.vless.Account"
	addUserOperationType = "xray.app.proxyman.command.AddUserOperation"
	removeUserOperation  = "xray.app.proxyman.command.RemoveUserOperation"
)

type Client struct {
	conn       *grpc.ClientConn
	inboundTag string
	timeout    time.Duration
}

type UserSpec struct {
	ID   string
	Flow string
}

func New(address, inboundTag string, timeout time.Duration) (*Client, error) {
	conn, err := grpc.NewClient(address,
		grpc.WithTransportCredentials(insecure.NewCredentials()),
		grpc.WithDefaultCallOptions(grpc.ForceCodec(wireCodec{})),
	)
	if err != nil {
		return nil, fmt.Errorf("create Xray API client: %w", err)
	}
	return &Client{conn: conn, inboundTag: inboundTag, timeout: timeout}, nil
}

func (c *Client) Close() error { return c.conn.Close() }

func (c *Client) ListUsers(ctx context.Context) (map[string]UserSpec, error) {
	ctx, cancel := c.withTimeout(ctx)
	defer cancel()
	var response getInboundUsersResponse
	err := c.conn.Invoke(ctx, handlerService+"GetInboundUsers", &getInboundUsersRequest{Tag: c.inboundTag}, &response)
	if err != nil {
		return nil, fmt.Errorf("list Xray inbound users: %w", err)
	}
	users := make(map[string]UserSpec, len(response.Users))
	for _, user := range response.Users {
		if user.Email == "" {
			continue
		}
		if user.Account.Type == vlessAccountType {
			users[user.Email] = UserSpec{ID: user.Account.ID, Flow: user.Account.Flow}
		} else {
			// Keep foreign accounts visible so the synchronizer removes them from
			// the adapter-managed VLESS inbound.
			users[user.Email] = UserSpec{}
		}
	}
	return users, nil
}

func (c *Client) AddUser(ctx context.Context, email, id string) error {
	request := &alterInboundRequest{
		Tag: c.inboundTag,
		Operation: typedMessage{
			Type: addUserOperationType,
			Value: marshalAddUserOperation(wireUser{
				Email:   email,
				Account: wireAccount{Type: vlessAccountType, ID: id, Flow: visionFlow},
			}),
		},
	}
	ctx, cancel := c.withTimeout(ctx)
	defer cancel()
	if err := c.conn.Invoke(ctx, handlerService+"AlterInbound", request, &emptyResponse{}); err != nil {
		return fmt.Errorf("add Xray user %q: %w", email, err)
	}
	return nil
}

func (c *Client) RemoveUser(ctx context.Context, email string) error {
	request := &alterInboundRequest{
		Tag: c.inboundTag,
		Operation: typedMessage{
			Type:  removeUserOperation,
			Value: marshalRemoveUserOperation(email),
		},
	}
	ctx, cancel := c.withTimeout(ctx)
	defer cancel()
	if err := c.conn.Invoke(ctx, handlerService+"AlterInbound", request, &emptyResponse{}); err != nil {
		return fmt.Errorf("remove Xray user %q: %w", email, err)
	}
	return nil
}

func (c *Client) FetchTraffic(ctx context.Context) (map[string]traffic.Counter, error) {
	ctx, cancel := c.withTimeout(ctx)
	defer cancel()
	var response queryStatsResponse
	if err := c.conn.Invoke(ctx, statsService+"QueryStats", &queryStatsRequest{Pattern: "user>>>"}, &response); err != nil {
		return nil, fmt.Errorf("query Xray traffic: %w", err)
	}
	counters := make(map[string]traffic.Counter)
	for _, stat := range response.Stats {
		parts := strings.Split(stat.Name, ">>>")
		if len(parts) != 4 || parts[0] != "user" || parts[2] != "traffic" || stat.Value < 0 {
			continue
		}
		if _, err := strconv.ParseInt(parts[1], 10, 64); err != nil {
			continue
		}
		counter := counters[parts[1]]
		switch parts[3] {
		case "uplink":
			counter.Tx = uint64(stat.Value)
		case "downlink":
			counter.Rx = uint64(stat.Value)
		default:
			continue
		}
		counters[parts[1]] = counter
	}
	return counters, nil
}

func (c *Client) withTimeout(ctx context.Context) (context.Context, context.CancelFunc) {
	return context.WithTimeout(ctx, c.timeout)
}

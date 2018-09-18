#pragma once

#include "hf/cpu.h"
#include "hf/vm.h"

struct vcpu *api_switch_to_primary(size_t primary_retval,
				   enum vcpu_state secondary_state);

int32_t api_vm_get_count(void);
int32_t api_vcpu_get_count(uint32_t vm_id);
int32_t api_vcpu_run(uint32_t vm_id, uint32_t vcpu_idx, struct vcpu **next);
struct vcpu *api_wait_for_interrupt(void);
int32_t api_vm_configure(ipaddr_t send, ipaddr_t recv);

int32_t api_rpc_request(uint32_t vm_id, size_t size);
int32_t api_rpc_read_request(bool block, struct vcpu **next);
int32_t api_rpc_reply(size_t size, bool ack, struct vcpu **next);
int32_t api_rpc_ack(void);
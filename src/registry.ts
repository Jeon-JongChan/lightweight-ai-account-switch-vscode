import { readdirSync } from 'node:fs';
import { join } from 'node:path';
import type { Agent } from './accounts';

/** agents 폴더의 전략을 자동 발견하여 중앙 등록 목록을 없앤다. */
export function discoverAgents(): Agent[] {
  const directory = join(__dirname, 'agents');
  const agents: Agent[] = [];
  for (const file of readdirSync(directory).sort()) {
    if (!file.endsWith('.js')) continue;
    const agent = require(join(directory, file)).default as Agent;
    if (!agent || !/^[a-z][a-z0-9-]*$/.test(agent.id) || !agent.label ||
        !agent.authPath || typeof agent.identify !== 'function' || typeof agent.read !== 'function' ||
        typeof agent.replace !== 'function' || agents.some(item => item.id === agent.id)) {
      throw new Error('잘못된 에이전트 어댑터');
    }
    agents.push(agent);
  }
  return agents;
}

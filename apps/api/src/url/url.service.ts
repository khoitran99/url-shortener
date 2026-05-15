import { Injectable, Inject } from '@nestjs/common';
import { CACHE_MANAGER } from '@nestjs/cache-manager';
import { Cache } from 'cache-manager';
import { PrismaService } from '../prisma/prisma.service';
import { encodeBase62 } from './base62';

const CACHE_PREFIX = 'redirect:';
const CACHE_TTL_MS = 24 * 60 * 60 * 1000;

@Injectable()
export class UrlService {
  constructor(
    private readonly prisma: PrismaService,
    @Inject(CACHE_MANAGER) private readonly cache: Cache,
  ) {}

  async shortenUrl(longUrl: string): Promise<string> {
    const existing = await this.prisma.url.findFirst({ where: { longUrl } });
    if (existing) return existing.shortUrl;

    const created = await this.prisma.url.create({
      data: { longUrl, shortUrl: '' },
    });

    const shortUrl = encodeBase62(created.id);

    await this.prisma.url.update({
      where: { id: created.id },
      data: { shortUrl },
    });

    await this.cache.set(`${CACHE_PREFIX}${shortUrl}`, longUrl, CACHE_TTL_MS);

    return shortUrl;
  }

  async getLongUrl(shortUrl: string): Promise<string | null> {
    const cached = await this.cache.get<string>(`${CACHE_PREFIX}${shortUrl}`);
    if (cached) return cached;

    const record = await this.prisma.url.findUnique({ where: { shortUrl } });
    if (!record) return null;

    await this.cache.set(`${CACHE_PREFIX}${shortUrl}`, record.longUrl, CACHE_TTL_MS);
    return record.longUrl;
  }
}

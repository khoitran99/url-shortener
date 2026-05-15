import { Test, TestingModule } from '@nestjs/testing';
import { CACHE_MANAGER } from '@nestjs/cache-manager';
import { UrlService } from './url.service';
import { PrismaService } from '../prisma/prisma.service';

const mockPrisma = {
  url: {
    findFirst: jest.fn(),
    findUnique: jest.fn(),
    create: jest.fn(),
    update: jest.fn(),
  },
};

const mockCache = {
  get: jest.fn(),
  set: jest.fn(),
};

describe('UrlService', () => {
  let service: UrlService;

  beforeEach(async () => {
    jest.clearAllMocks();

    const module: TestingModule = await Test.createTestingModule({
      providers: [
        UrlService,
        { provide: PrismaService, useValue: mockPrisma },
        { provide: CACHE_MANAGER, useValue: mockCache },
      ],
    }).compile();

    service = module.get<UrlService>(UrlService);
  });

  describe('shortenUrl', () => {
    it('returns existing short code when longUrl already in DB', async () => {
      mockPrisma.url.findFirst.mockResolvedValue({ id: 1n, shortUrl: 'abc1234', longUrl: 'https://example.com' });

      const result = await service.shortenUrl('https://example.com');

      expect(result).toBe('abc1234');
      expect(mockPrisma.url.create).not.toHaveBeenCalled();
    });

    it('creates a new short code for a new longUrl', async () => {
      mockPrisma.url.findFirst.mockResolvedValue(null);
      mockPrisma.url.create.mockResolvedValue({ id: 1n, shortUrl: '', longUrl: 'https://new.com' });
      mockPrisma.url.update.mockResolvedValue({ id: 1n, shortUrl: '1', longUrl: 'https://new.com' });

      const result = await service.shortenUrl('https://new.com');

      expect(mockPrisma.url.create).toHaveBeenCalledWith({
        data: { longUrl: 'https://new.com', shortUrl: '' },
      });
      expect(mockPrisma.url.update).toHaveBeenCalled();
      expect(result).toBe('1');
    });

    it('caches the new short code after creation', async () => {
      mockPrisma.url.findFirst.mockResolvedValue(null);
      mockPrisma.url.create.mockResolvedValue({ id: 62n, shortUrl: '', longUrl: 'https://cache-test.com' });
      mockPrisma.url.update.mockResolvedValue({ id: 62n, shortUrl: '10', longUrl: 'https://cache-test.com' });

      await service.shortenUrl('https://cache-test.com');

      expect(mockCache.set).toHaveBeenCalledWith('redirect:10', 'https://cache-test.com', expect.any(Number));
    });
  });

  describe('getLongUrl', () => {
    it('returns longUrl from cache without hitting DB', async () => {
      mockCache.get.mockResolvedValue('https://cached.com');

      const result = await service.getLongUrl('abc1234');

      expect(result).toBe('https://cached.com');
      expect(mockPrisma.url.findUnique).not.toHaveBeenCalled();
    });

    it('falls back to DB on cache miss and caches the result', async () => {
      mockCache.get.mockResolvedValue(null);
      mockPrisma.url.findUnique.mockResolvedValue({ id: 1n, shortUrl: 'abc1234', longUrl: 'https://db.com' });

      const result = await service.getLongUrl('abc1234');

      expect(result).toBe('https://db.com');
      expect(mockCache.set).toHaveBeenCalledWith('redirect:abc1234', 'https://db.com', expect.any(Number));
    });

    it('returns null for an unknown shortUrl', async () => {
      mockCache.get.mockResolvedValue(null);
      mockPrisma.url.findUnique.mockResolvedValue(null);

      const result = await service.getLongUrl('unknown');

      expect(result).toBeNull();
    });
  });
});
